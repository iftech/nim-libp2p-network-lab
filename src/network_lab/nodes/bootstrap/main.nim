# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import chronos, chronicles
import libp2p
import network_lab/common/[coordinator, gossipsub_node, shutdown]

logScope:
  topics = "network-lab"

proc main*(
    started: Future[MultiAddress] = nil, shutdownRequested: AsyncEvent = nil
): Future[int] {.async.} =
  let config = loadConfig(true)
  if config.isErr:
    error "Invalid bootstrap configuration", error = config.error
    return 1
  let cfg = config.get()
  let built = buildSwitch(cfg.listen)
  if built.isErr:
    error "Cannot build bootstrap switch", error = built.error
    return 1
  let switch = built.get()
  defer:
    await switch.stop()
  let
    rng = libp2p.newRng()
    coordinator = newCoordinator(cfg.participants, cfg.configSignature())
  discard mountBase(switch, rng)
  switch.mount(coordinator.protocol())
  await switch.start()
  let addresses = switch.peerInfo.fullAddrs()
  if addresses.isErr or addresses.get().len == 0:
    error "Bootstrap has no advertised address"
    return 1
  info "Bootstrap started",
    peerId = switch.peerInfo.peerId,
    addresses = addresses.get(),
    transport = cfg.transport,
    libp2pRevision = Libp2pRevision,
    participants = cfg.participants,
    timeoutSeconds = cfg.timeoutSeconds
  if started != nil and not started.finished():
    started.complete(addresses.get()[0])
  let shutdown =
    if shutdownRequested == nil:
      waitShutdownSignal()
    else:
      shutdownRequested.wait()
  defer:
    await noCancel shutdown.cancelAndWait()
  let deadline = Moment.now() + cfg.timeoutSeconds.seconds
  var previousPhase = ""
  while not shutdown.finished():
    let currentPhase = coordinator.phase()
    if currentPhase != previousPhase:
      info "Coordinator phase",
        phase = currentPhase,
        registered = coordinator.registered(),
        ready = coordinator.ready.len,
        published = coordinator.published.len,
        verified = coordinator.verified.len,
        expected = cfg.participants
      previousPhase = currentPhase
    if currentPhase == "failed":
      error "Bootstrap observed failure", reason = coordinator.failure
      return 1
    if currentPhase != "complete" and Moment.now() >= deadline:
      error "Bootstrap coordination timed out",
        phase = currentPhase,
        registered = coordinator.registered(),
        ready = coordinator.ready.len,
        published = coordinator.published.len,
        verified = coordinator.verified.len,
        expected = cfg.participants
      return 1
    await sleepAsync(1.seconds)
  if coordinator.phase() != "complete":
    error "Bootstrap stopped before experiment completed", phase = coordinator.phase()
    return 1
  info "Bootstrap stopped after experiment completed"
  return 0

when isMainModule:
  try:
    quit(waitFor(main()))
  except CatchableError as exc:
    error "Bootstrap fatal error", error = exc.msg
    quit(1)
