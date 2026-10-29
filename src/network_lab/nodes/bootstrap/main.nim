# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import chronos, chronicles
import libp2p
import results
import network_lab/common/[coordinator, env_values, gossipsub_node, shutdown]

logScope:
  topics = "network-lab"

const BootstrapStatusPollInterval = 1.seconds

proc waitForRequestedShutdown(
    event: AsyncEvent
): Future[Result[void, string]] {.async: (raises: [CancelledError]).} =
  try:
    await event.wait()
    return ok()
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    return err(exc.msg)

proc monitorCoordinator(
    coordinator: Coordinator,
    cfg: NodeConfig,
    shutdownResult: Future[Result[void, string]],
    deadline: Moment,
): Future[Result[void, string]] {.async.} =
  var previousPhase = ""
  while not shutdownResult.finished():
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
      return err("Bootstrap observed failure: " & coordinator.failure)
    if currentPhase != "complete" and Moment.now() >= deadline:
      return err("Bootstrap coordination timed out in phase " & currentPhase)
    await sleepAsync(BootstrapStatusPollInterval)

  var shutdownCompletionResult: Result[void, string]
  try:
    shutdownCompletionResult = await shutdownResult
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    return err(exc.msg)
  if shutdownCompletionResult.isErr:
    return err(shutdownCompletionResult.error)
  if coordinator.phase() != "complete":
    return err("Bootstrap stopped before experiment completed")
  ok()

proc main*(
    started: Future[MultiAddress] = nil, shutdownRequested: AsyncEvent = nil
): Future[int] {.async.} =
  let configResult = loadEnvConfig(true)
  if configResult.isErr:
    error "Invalid bootstrap configuration", error = configResult.error
    return 1
  let cfg = configResult.get()
  let switchResult = buildSwitch(cfg.listen)
  if switchResult.isErr:
    error "Cannot build bootstrap switch", error = switchResult.error
    return 1
  let switch = switchResult.get()
  defer:
    await switch.stop()
  let
    rng = libp2p.newRng()
    coordinator = newCoordinator(cfg.participants, cfg.configSignature())
  discard mountBase(switch, rng)
  switch.mount(coordinator.protocol())
  let startResult = await startSwitch(switch)
  if startResult.isErr:
    error "Cannot start bootstrap switch", error = startResult.error
    return 1
  let addressesResult = switch.peerInfo.fullAddrs()
  if addressesResult.isErr or addressesResult.get().len == 0:
    error "Bootstrap has no advertised address"
    return 1
  info "Bootstrap started",
    peerId = switch.peerInfo.peerId,
    addresses = addressesResult.get(),
    transport = cfg.transport,
    libp2pRevision = Libp2pRevision,
    participants = cfg.participants,
    timeoutSeconds = cfg.timeoutSeconds
  if started != nil and not started.finished():
    started.complete(addressesResult.get()[0])
  let shutdownResult =
    if shutdownRequested == nil:
      waitShutdownSignal()
    else:
      waitForRequestedShutdown(shutdownRequested)
  defer:
    await noCancel shutdownResult.cancelAndWait()
  let deadline = Moment.now() + cfg.timeoutSeconds.seconds
  let monitorResult =
    await monitorCoordinator(coordinator, cfg, shutdownResult, deadline)
  if monitorResult.isErr:
    error "Bootstrap coordination failed", reason = monitorResult.error
    return 1
  info "Bootstrap stopped after experiment completed"
  return 0

when isMainModule:
  try:
    quit(waitFor(main()))
  except CatchableError as exc:
    error "Bootstrap fatal error", error = exc.msg
    quit(1)
