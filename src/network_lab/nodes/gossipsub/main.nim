# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import std/[os, sequtils, sets, tables]
import chronos, chronicles
import results
import stew/byteutils
import libp2p
import libp2p/protocols/[kademlia, ping]
import libp2p/protocols/pubsub/rpc/messages
import network_lab/common/[coordinator, env_values, gossipsub_node, regression_messages]

logScope:
  topics = "network-lab"

const
  KeepalivePingTimeout = 4.seconds
  CoordinatorRequestTimeout = 10.seconds
  BootstrapDialTimeout = 10.seconds
  BootstrapPingTimeout = 10.seconds
  KadBootstrapTimeout = 30.seconds
  CoordinatorRetryDelay = 2.seconds
  BootstrapRetryDelay = 2.seconds
  PeerDiscoveryRetryDelay = 3.seconds
  PublishInterval = 1.seconds
  DeliveryCheckInterval = 1.seconds
  DeliveryVerificationTimeout = 60.seconds
  FailureReportTimeout = 5.seconds
  NoDelay = 0.milliseconds
  KeepaliveInterval = 12.seconds
  KeepaliveBatchDelay = 200.milliseconds

proc makeHandler(state: Received, cfg: NodeConfig): TopicHandler =
  return proc(topic: string, data: seq[byte]) {.async, gcsafe.} =
    let raw = string.fromBytes(data)
    let recordedResult = state.record(raw, cfg.index, cfg.participants, cfg.rounds)
    if recordedResult.isOk:
      state.publishingStarted = true
    else:
      state.failure = recordedResult.error
      error "Invalid GossipSub message",
        nodeIndex = cfg.index,
        topic = topic,
        payload = raw,
        error = recordedResult.error

proc makeValidator(cfg: NodeConfig): ValidatorHandler =
  return proc(
      topic: string, message: messages.Message
  ): Future[ValidationResult] {.async.} =
    return
      (if topic == cfg.topic: ValidationResult.Accept else: ValidationResult.Reject)

proc pingConnectedPeer(
    switch: Switch, ping: Ping, peer: PeerId
): Future[void] {.async.} =
  var stream: Stream
  try:
    stream = await switch.dial(peer, PingCodec).wait(KeepalivePingTimeout)
    discard await ping.ping(stream).wait(KeepalivePingTimeout)
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    warn "Keepalive ping failed", peerId = peer, error = exc.msg
  finally:
    if stream != nil:
      await stream.close()

proc keepPeersAlive(
    switch: Switch, ping: Ping, state: Received
): Future[void] {.async.} =
  const maxPeersPerPin = 32

  while not state.publishingStarted:
    var batch: seq[Future[void]]

    for peer in toSeq(switch.connManager.connectedPeers()):
      if state.publishingStarted:
        break

      if peer != switch.peerInfo.peerId:
        batch.add(pingConnectedPeer(switch, ping, peer))

      if batch.len == maxPeersPerPin:
        await allFutures(batch)
        batch.setLen(0)
        await sleepAsync(KeepaliveBatchDelay)

    if batch.len > 0:
      await allFutures(batch)
    await sleepAsync(KeepaliveInterval)

proc awaitPhase(
    switch: Switch,
    peer: PeerId,
    cfg: NodeConfig,
    state: Received,
    command, desired: string,
    deadline: Moment,
): Future[Result[void, string]] {.async.} =
  var lastError = ""
  while Moment.now() < deadline:
    if state.failure.len > 0:
      return Result[void, string].err(state.failure)

    try:
      let phaseResult = await exchange(
        switch, peer, command, cfg.index, cfg.configSignature()
      )
        .wait(CoordinatorRequestTimeout)
      if phaseResult.isErr:
        lastError = phaseResult.error
        warn "Coordinator request failed; retrying",
          nodeIndex = cfg.index, command = command, error = lastError
      elif phaseResult.get() == "failed":
        return Result[void, string].err("bootstrap reported experiment failure")
      elif phaseResult.get() == desired:
        return Result[void, string].ok()
      else:
        lastError = "coordinator phase: " & phaseResult.get()
    except CancelledError as exc:
      raise exc
    except CatchableError as exc:
      lastError = exc.msg
      warn "Coordinator request failed; retrying",
        nodeIndex = cfg.index, command = command, error = exc.msg

    await sleepAsync(CoordinatorRetryDelay)

  Result[void, string].err("Timed out waiting for " & desired & ": " & lastError)

type BootstrapConnection = object
  peerId: PeerId
  address: MultiAddress
  attempts: int

proc connectToBootstrap(
    switch: Switch, cfg: NodeConfig, deadline: Moment
): Future[Result[BootstrapConnection, string]] {.async.} =
  let rawOverride = getEnv("BOOTSTRAP_ADDR")
  var candidates: seq[MultiAddress]
  if rawOverride.len > 0:
    let parsed = getEnvBootstrapAddress()
    if parsed.isErr:
      return Result[BootstrapConnection, string].err(parsed.error)
    candidates.add(MultiAddress.init(rawOverride).get())
  let target =
    if rawOverride.len > 0:
      rawOverride
    else:
      cfg.bootstrapHost & ":" & $cfg.bootstrapPort

  await sleepAsync(
    min((cfg.index * cfg.staggerMs).milliseconds, max(deadline - Moment.now(), NoDelay))
  )

  var
    connection: BootstrapConnection
    connected = false
    lastError = ""
  while Moment.now() < deadline and not connected:
    inc connection.attempts
    try:
      if rawOverride.len == 0:
        candidates.setLen(0)
        for address in resolveTAddress(target):
          if cfg.transport == "QUIC":
            let quic = MultiAddress.init("/quic-v1").tryGet()
            candidates.add(
              MultiAddress.init(address, IPPROTO_UDP).tryGet().concat(quic).tryGet()
            )
          else:
            candidates.add(MultiAddress.init(address).tryGet())
      if candidates.len == 0:
        lastError = "DNS returned no addresses"
      for address in candidates:
        try:
          connection.peerId = await switch
            .connect(address, allowUnknownPeerId = true)
            .wait(BootstrapDialTimeout)
          connection.address = address
          connected = true
          break
        except CancelledError as exc:
          raise exc
        except CatchableError as exc:
          lastError = exc.msg
          warn "Bootstrap dial failed; retrying",
            nodeIndex = cfg.index,
            address = address,
            attempt = connection.attempts,
            error = exc.msg
    except CancelledError as exc:
      raise exc
    except CatchableError as exc:
      lastError = exc.msg
      warn "Bootstrap resolution failed; retrying",
        nodeIndex = cfg.index,
        target = target,
        attempt = connection.attempts,
        error = exc.msg
    if not connected:
      await sleepAsync(BootstrapRetryDelay)

  if not connected:
    error "Cannot connect to bootstrap",
      nodeIndex = cfg.index,
      address = target,
      attempts = connection.attempts,
      error = lastError
    return Result[BootstrapConnection, string].err(lastError)

  info "Connected to bootstrap",
    nodeIndex = cfg.index,
    bootstrapPeerId = connection.peerId,
    bootstrapAddress = connection.address,
    attempts = connection.attempts
  Result[BootstrapConnection, string].ok(connection)

proc registerWithBootstrap(
    switch: Switch,
    cfg: NodeConfig,
    base: tuple[kad: KadDHT, ping: Ping],
    state: Received,
    connection: BootstrapConnection,
    deadline: Moment,
): Future[Result[void, string]] {.async.} =
  try:
    let phaseResult = await awaitPhase(
      switch, connection.peerId, cfg, state, "register", "ready", deadline
    )
    if phaseResult.isErr:
      return Result[void, string].err(phaseResult.error)
    let pingStream =
      await switch.dial(connection.peerId, PingCodec).wait(BootstrapPingTimeout)
    try:
      let latency = await base.ping.ping(pingStream).wait(BootstrapPingTimeout)
      info "Bootstrap ping succeeded", nodeIndex = cfg.index, latency = latency
    finally:
      await pingStream.close()

    base.kad.updatePeers(@[(connection.peerId, @[connection.address])])
    return Result[void, string].ok()
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    return Result[void, string].err(exc.msg)

proc discoverParticipants(
    switch: Switch,
    cfg: NodeConfig,
    base: tuple[kad: KadDHT, ping: Ping],
    gossip: GossipSub,
    state: Received,
    connection: BootstrapConnection,
    deadline: Moment,
): Future[Result[void, string]] {.async.} =
  try:
    while Moment.now() < deadline and gossip.mesh.getOrDefault(cfg.topic).len == 0:
      try:
        await base.kad.bootstrap(forceRefresh = true).wait(KadBootstrapTimeout)
      except AsyncTimeoutError:
        warn "Kad-DHT discovery timed out; retrying", nodeIndex = cfg.index
      info "Discovering GossipSub peers",
        nodeIndex = cfg.index,
        topicPeers = gossip.remotePeerCount(cfg.topic),
        meshPeers = gossip.mesh.getOrDefault(cfg.topic).len
      if gossip.mesh.getOrDefault(cfg.topic).len == 0:
        await sleepAsync(PeerDiscoveryRetryDelay)
    if gossip.mesh.getOrDefault(cfg.topic).len == 0:
      return Result[void, string].err(
        "No remote GossipSub participant discovered before deadline"
      )
    let phaseResult = await awaitPhase(
      switch, connection.peerId, cfg, state, "ready", "publish", deadline
    )
    if phaseResult.isErr:
      return Result[void, string].err(phaseResult.error)
    info "All participants ready",
      nodeIndex = cfg.index, topicPeers = gossip.remotePeerCount(cfg.topic)
    return Result[void, string].ok()
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    return Result[void, string].err(exc.msg)

proc publishMessages(
    gossip: GossipSub, cfg: NodeConfig, state: Received
): Future[Result[void, string]] {.async.} =
  try:
    await sleepAsync((cfg.index * cfg.staggerMs).milliseconds)
    for round in 0 ..< cfg.rounds:
      let payload = message(state.runId, cfg.index, round)
      let peers = await gossip.publish(cfg.topic, payload.toBytes())
      if peers == 0:
        return
          Result[void, string].err("Publish had no remote peers for round " & $round)
      info "Published test message", nodeIndex = cfg.index, round = round, peers = peers
      await sleepAsync(PublishInterval)
    return Result[void, string].ok()
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    return Result[void, string].err(exc.msg)

proc verifyDelivery(
    switch: Switch,
    cfg: NodeConfig,
    gossip: GossipSub,
    state: Received,
    connection: BootstrapConnection,
    deadline: Moment,
): Future[Result[void, string]] {.async.} =
  try:
    let phaseResult = await awaitPhase(
      switch, connection.peerId, cfg, state, "published", "verify", deadline
    )
    if phaseResult.isErr:
      return Result[void, string].err(phaseResult.error)
    let
      expected = (cfg.participants - 1) * cfg.rounds
      required = requiredDeliveries(cfg.participants, cfg.rounds, cfg.threshold)
      deliveryDeadline = min(deadline, Moment.now() + DeliveryVerificationTimeout)
    while state.seen.len < required and state.failure.len == 0 and
        Moment.now() < deliveryDeadline:
      await sleepAsync(DeliveryCheckInterval)
    info "GossipSub delivery result",
      nodeIndex = cfg.index,
      received = state.seen.len,
      expected = expected,
      required = required,
      selfReceived = state.selfCount,
      topicPeers = gossip.remotePeerCount(cfg.topic),
      meshPeers = gossip.mesh.getOrDefault(cfg.topic).len
    if state.failure.len > 0:
      return Result[void, string].err(state.failure)
    if state.selfCount != cfg.rounds:
      return Result[void, string].err(
        "Self-delivery count " & $state.selfCount & " does not match " & $cfg.rounds
      )
    if state.seen.len < required:
      var missing: seq[string]
      for index in 0 ..< cfg.participants:
        if index != cfg.index:
          for round in 0 ..< cfg.rounds:
            let id = $index & ":" & $round
            if id notin state.seen:
              missing.add(id)
      error "Delivery below threshold",
        nodeIndex = cfg.index,
        received = state.seen.len,
        expected = expected,
        required = required,
        missing = missing
      return Result[void, string].err("delivery below configured threshold")
    let completionResult = await awaitPhase(
      switch, connection.peerId, cfg, state, "verified", "complete", deadline
    )
    if completionResult.isErr:
      return Result[void, string].err(completionResult.error)
    info "GossipSub self-check passed",
      nodeIndex = cfg.index,
      received = state.seen.len,
      expected = expected,
      threshold = cfg.threshold
    return Result[void, string].ok()
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    return Result[void, string].err(exc.msg)

proc reportPhaseFailure(
    switch: Switch, cfg: NodeConfig, bootstrapPeerId: PeerId, message: string
): Future[void] {.async.} =
  error "GossipSub self-check failed",
    nodeIndex = cfg.index,
    peerId = switch.peerInfo.peerId,
    bootstrapPeerId,
    error = message
  try:
    discard await exchange(
      switch, bootstrapPeerId, "failed", cfg.index, cfg.configSignature()
    )
      .wait(FailureReportTimeout)
  except CancelledError as exc:
    raise exc
  except CatchableError:
    discard

proc runExperiment(
    switch: Switch,
    cfg: NodeConfig,
    base: tuple[kad: KadDHT, ping: Ping],
    gossip: GossipSub,
    state: Received,
    deadline: Moment,
): Future[Result[void, string]] {.async.} =
  let connectionResult = await connectToBootstrap(switch, cfg, deadline)
  if connectionResult.isErr:
    return Result[void, string].err(connectionResult.error)
  let connection = connectionResult.get()
  state.runId = $connection.peerId

  let keepalive = keepPeersAlive(switch, base.ping, state)
  defer:
    await noCancel keepalive.cancelAndWait()

  let registrationResult =
    await registerWithBootstrap(switch, cfg, base, state, connection, deadline)
  if registrationResult.isErr:
    await reportPhaseFailure(switch, cfg, connection.peerId, registrationResult.error)
    return Result[void, string].err(registrationResult.error)

  let discoveryResult =
    await discoverParticipants(switch, cfg, base, gossip, state, connection, deadline)
  if discoveryResult.isErr:
    await reportPhaseFailure(switch, cfg, connection.peerId, discoveryResult.error)
    return Result[void, string].err(discoveryResult.error)

  let publishingResult = await publishMessages(gossip, cfg, state)
  if publishingResult.isErr:
    await reportPhaseFailure(switch, cfg, connection.peerId, publishingResult.error)
    return Result[void, string].err(publishingResult.error)

  let verificationResult =
    await verifyDelivery(switch, cfg, gossip, state, connection, deadline)
  if verificationResult.isErr:
    await reportPhaseFailure(switch, cfg, connection.peerId, verificationResult.error)
    return Result[void, string].err(verificationResult.error)
  Result[void, string].ok()

proc run(): Future[int] {.async.} =
  let configResult = loadEnvConfig(false)
  if configResult.isErr:
    error "Invalid GossipSub configuration", error = configResult.error
    return 1
  let cfg = configResult.get()

  let switchResult = buildSwitch(cfg.listen)
  if switchResult.isErr:
    error "Cannot build GossipSub switch", error = switchResult.error
    return 1

  let
    switch = switchResult.get()
    base = mountBase(switch, switch.rng)
    gossip = buildGossipSub(switch, switch.rng)
    state = Received()
    deadline = Moment.now() + cfg.timeoutSeconds.seconds
  gossip.topicParams[cfg.topic] = TopicParams(
    topicWeight: 1,
    firstMessageDeliveriesWeight: 1,
    firstMessageDeliveriesCap: 30,
    firstMessageDeliveriesDecay: 0.9,
  )

  gossip.subscribe(cfg.topic, makeHandler(state, cfg))
  gossip.addValidator([cfg.topic], makeValidator(cfg))
  switch.mount(gossip)

  defer:
    await switch.stop()

  let startResult = await startSwitch(switch)
  if startResult.isErr:
    error "Cannot start GossipSub switch", error = startResult.error
    return 1

  info "GossipSub node started",
    nodeIndex = cfg.index,
    peerId = switch.peerInfo.peerId,
    addresses = switch.peerInfo.addrs,
    transport = cfg.transport,
    libp2pRevision = Libp2pRevision,
    topic = cfg.topic,
    participants = cfg.participants,
    rounds = cfg.rounds,
    threshold = cfg.threshold

  let experimentResult = await runExperiment(switch, cfg, base, gossip, state, deadline)
  if experimentResult.isErr:
    error "GossipSub node failed", error = experimentResult.error
    return 1
  return 0

proc main*(): Future[int] {.async.} =
  try:
    return await run()
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    error "GossipSub fatal error", error = exc.msg
    return 1

when isMainModule:
  try:
    quit(waitFor(main()))
  except CatchableError as exc:
    error "GossipSub fatal error", error = exc.msg
    quit(1)
