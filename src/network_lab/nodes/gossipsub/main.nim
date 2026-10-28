# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import std/[os, sets, tables]
import chronos, chronicles
import stew/byteutils
import libp2p
import libp2p/protocols/[kademlia, ping]
import libp2p/protocols/pubsub/rpc/messages
import network_lab/common/[coordinator, gossipsub_node, regression_messages]

logScope:
  topics = "network-lab"

proc makeHandler(state: Received, cfg: NodeConfig): TopicHandler =
  return proc(topic: string, data: seq[byte]) {.async, gcsafe.} =
    let raw = string.fromBytes(data)
    let recorded = state.record(raw, cfg.index, cfg.participants, cfg.rounds)
    if recorded.isOk:
      state.publishingStarted = true
    else:
      state.failure = recorded.error
      error "Invalid GossipSub message",
        nodeIndex = cfg.index, topic = topic, payload = raw, error = recorded.error

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
    stream = await switch.dial(peer, PingCodec).wait(4.seconds)
    discard await ping.ping(stream).wait(4.seconds)
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
  while not state.publishingStarted:
    var
      batch: seq[Future[void]]
      peers: seq[PeerId]
    for peer in switch.connManager.getConnections().keys:
      peers.add(peer)
    for peer in peers:
      if state.publishingStarted:
        break
      if peer != switch.peerInfo.peerId:
        batch.add(pingConnectedPeer(switch, ping, peer))
      if batch.len == 16:
        await allFutures(batch)
        batch.setLen(0)
        await sleepAsync(200.milliseconds)
    if batch.len > 0:
      await allFutures(batch)
    await sleepAsync(12.seconds)

proc awaitPhase(
    switch: Switch,
    peer: PeerId,
    cfg: NodeConfig,
    state: Received,
    command, desired: string,
    deadline: Moment,
): Future[void] {.async.} =
  var lastError = ""
  while Moment.now() < deadline:
    if state.failure.len > 0:
      raise newException(ValueError, state.failure)
    try:
      let phase = await exchange(
        switch, peer, command, cfg.index, cfg.configSignature()
      )
        .wait(10.seconds)
      if phase == "failed":
        raise newException(ValueError, "bootstrap reported experiment failure")
      if phase == desired:
        return
      lastError = "coordinator phase: " & phase
    except CancelledError as exc:
      raise exc
    except ValueError as exc:
      raise exc
    except CatchableError as exc:
      lastError = exc.msg
      warn "Coordinator request failed; retrying",
        nodeIndex = cfg.index, command = command, error = exc.msg
    await sleepAsync(2.seconds)
  raise newException(ValueError, "Timed out waiting for " & desired & ": " & lastError)

proc run(): Future[int] {.async.} =
  let config = loadConfig(false)
  if config.isErr:
    error "Invalid GossipSub configuration", error = config.error
    return 1
  let cfg = config.get()
  let built = buildSwitch(cfg.listen)
  if built.isErr:
    error "Cannot build GossipSub switch", error = built.error
    return 1
  let switch = built.get()
  defer:
    await switch.stop()
  let
    rng = libp2p.newRng()
    base = mountBase(switch, rng)
    gossip = buildGossipSub(switch, rng)
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
  await switch.start()
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
  let overrideAddress = getEnv("BOOTSTRAP_ADDR")
  var candidates: seq[MultiAddress]
  if overrideAddress.len > 0:
    let parsed = MultiAddress.init(overrideAddress)
    if parsed.isErr:
      error "Invalid bootstrap address",
        address = overrideAddress, error = $parsed.error
      return 1
    candidates.add(parsed.get())
  let bootstrapTarget =
    if overrideAddress.len > 0:
      overrideAddress
    else:
      cfg.bootstrapHost & ":" & $cfg.bootstrapPort
  await sleepAsync((cfg.index * cfg.staggerMs).milliseconds)
  var
    bootstrapPeer: PeerId
    bootstrapAddr: MultiAddress
    connected = false
    attempt = 0
    lastError = ""
  while Moment.now() < deadline and not connected:
    inc attempt
    try:
      if overrideAddress.len == 0:
        candidates.setLen(0)
        for address in resolveTAddress(bootstrapTarget):
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
          bootstrapPeer =
            await switch.connect(address, allowUnknownPeerId = true).wait(10.seconds)
          bootstrapAddr = address
          connected = true
          break
        except CancelledError as exc:
          raise exc
        except CatchableError as exc:
          lastError = exc.msg
          warn "Bootstrap dial failed; retrying",
            nodeIndex = cfg.index, address = address, attempt = attempt, error = exc.msg
    except CancelledError as exc:
      raise exc
    except CatchableError as exc:
      lastError = exc.msg
      warn "Bootstrap resolution failed; retrying",
        nodeIndex = cfg.index,
        target = bootstrapTarget,
        attempt = attempt,
        error = exc.msg
    if not connected:
      await sleepAsync(2.seconds)
  if not connected:
    error "Cannot connect to bootstrap",
      nodeIndex = cfg.index,
      address = bootstrapTarget,
      attempts = attempt,
      error = lastError
    return 1
  state.runId = $bootstrapPeer
  info "Connected to bootstrap",
    nodeIndex = cfg.index,
    bootstrapPeerId = bootstrapPeer,
    bootstrapAddress = bootstrapAddr,
    attempts = attempt
  try:
    let keepalive = keepPeersAlive(switch, base.ping, state)
    defer:
      await noCancel keepalive.cancelAndWait()
    await awaitPhase(switch, bootstrapPeer, cfg, state, "register", "ready", deadline)
    let pingStream = await switch.dial(bootstrapPeer, PingCodec).wait(10.seconds)
    try:
      let latency = await base.ping.ping(pingStream).wait(10.seconds)
      info "Bootstrap ping succeeded", nodeIndex = cfg.index, latency = latency
    finally:
      await pingStream.close()
    base.kad.updatePeers(@[(bootstrapPeer, @[bootstrapAddr])])
    while Moment.now() < deadline and gossip.mesh.getOrDefault(cfg.topic).len == 0:
      try:
        await base.kad.bootstrap(forceRefresh = true).wait(30.seconds)
      except AsyncTimeoutError:
        warn "Kad-DHT discovery timed out; retrying", nodeIndex = cfg.index
      info "Discovering GossipSub peers",
        nodeIndex = cfg.index,
        topicPeers = gossip.remotePeerCount(cfg.topic),
        meshPeers = gossip.mesh.getOrDefault(cfg.topic).len
      if gossip.mesh.getOrDefault(cfg.topic).len == 0:
        await sleepAsync(3.seconds)
    if gossip.mesh.getOrDefault(cfg.topic).len == 0:
      raise newException(
        ValueError, "No remote GossipSub participant discovered before deadline"
      )
    await awaitPhase(switch, bootstrapPeer, cfg, state, "ready", "publish", deadline)
    info "All participants ready",
      nodeIndex = cfg.index, topicPeers = gossip.remotePeerCount(cfg.topic)
    await sleepAsync((cfg.index * 50).milliseconds)
    for round in 0 ..< cfg.rounds:
      let payload = message(state.runId, cfg.index, round)
      let peers = await gossip.publish(cfg.topic, payload.toBytes())
      if peers == 0:
        raise
          newException(ValueError, "Publish had no remote peers for round " & $round)
      info "Published test message", nodeIndex = cfg.index, round = round, peers = peers
      await sleepAsync(1.seconds)
    await awaitPhase(switch, bootstrapPeer, cfg, state, "published", "verify", deadline)
    let
      expected = (cfg.participants - 1) * cfg.rounds
      required = requiredDeliveries(cfg.participants, cfg.rounds, cfg.threshold)
      deliveryDeadline = min(deadline, Moment.now() + 60.seconds)
    while state.seen.len < required and state.failure.len == 0 and
        Moment.now() < deliveryDeadline:
      await sleepAsync(1.seconds)
    info "GossipSub delivery result",
      nodeIndex = cfg.index,
      received = state.seen.len,
      expected = expected,
      required = required,
      selfReceived = state.selfCount,
      topicPeers = gossip.remotePeerCount(cfg.topic),
      meshPeers = gossip.mesh.getOrDefault(cfg.topic).len
    if state.failure.len > 0:
      raise newException(ValueError, state.failure)
    if state.selfCount != cfg.rounds:
      raise newException(
        ValueError,
        "Self-delivery count " & $state.selfCount & " does not match " & $cfg.rounds,
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
      raise newException(ValueError, "delivery below configured threshold")
    await awaitPhase(
      switch, bootstrapPeer, cfg, state, "verified", "complete", deadline
    )
    info "GossipSub self-check passed",
      nodeIndex = cfg.index,
      received = state.seen.len,
      expected = expected,
      threshold = cfg.threshold
    return 0
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    error "GossipSub self-check failed",
      nodeIndex = cfg.index,
      peerId = switch.peerInfo.peerId,
      bootstrapPeerId = bootstrapPeer,
      error = exc.msg
    try:
      discard await exchange(
        switch, bootstrapPeer, "failed", cfg.index, cfg.configSignature()
      )
        .wait(5.seconds)
    except CatchableError:
      discard
    return 1

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
