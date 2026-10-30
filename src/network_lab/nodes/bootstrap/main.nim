# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import std/sets
import chronos, chronicles
import libp2p
import results
import
  network_lab/common/
    [coordinator, env_values, failure_context, gossipsub_node, shutdown]

logScope:
  topics = "network-lab"

const
  BootstrapStatusPollInterval = 1.seconds
  FailureNotificationTimeout = 30.seconds

proc monitorCoordinator(
    coordinator: Coordinator,
    cfg: NodeConfig,
    shutdownSignal: Future[void],
    deadline: Moment,
): Future[Result[void, string]] {.async.} =
  var previousPhase = ""
  while not shutdownSignal.finished():
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
      let notificationDeadline = Moment.now() + FailureNotificationTimeout
      while coordinator.failureNotified.len < cfg.participants and
          Moment.now() < notificationDeadline and not shutdownSignal.finished():
        await sleepAsync(BootstrapStatusPollInterval)
      info "Failure notification finished",
        notified = coordinator.failureNotified.len, expected = cfg.participants
      return err("Bootstrap observed failure: " & coordinator.failure)
    if currentPhase == "complete" and
        coordinator.completionNotified.len == cfg.participants:
      return ok()
    if Moment.now() >= deadline:
      return err(
        "Bootstrap coordination timed out in phase " & currentPhase & ": registered=" &
          $coordinator.registered() & ", ready=" & $coordinator.ready.len &
          ", published=" & $coordinator.published.len & ", verified=" &
          $coordinator.verified.len & ", completion notified=" &
          $coordinator.completionNotified.len & ", expected=" & $cfg.participants
      )
    # Coordinator phase changes have no notification; polling also bounds shutdown
    # detection latency to one status interval.
    await sleepAsync(BootstrapStatusPollInterval)

  await shutdownSignal
  if coordinator.phase() != "complete" or
      coordinator.completionNotified.len != cfg.participants:
    return err(
      "Bootstrap stopped before experiment completed in phase " & coordinator.phase()
    )
  ok()

proc main*(
    started: Future[MultiAddress] = nil, shutdownRequested: AsyncEvent = nil
): Future[int] {.async.} =
  defer:
    if started != nil and not started.finished():
      started.fail(newException(IOError, "Bootstrap startup did not complete"))

  template startupFailure(category, message: string) =
    recordFailure("bootstrap", "startup", category, message)
    if started != nil and not started.finished():
      started.fail(newException(IOError, message))
    return 1

  let configResult = loadEnvConfig(true)
  if configResult.isErr:
    error "Invalid bootstrap configuration", error = configResult.error
    startupFailure("configuration", configResult.error)
  let cfg = configResult.get()
  let switchResult = buildSwitch(cfg.listen)
  if switchResult.isErr:
    error "Cannot build bootstrap switch", error = switchResult.error
    startupFailure("switch_build", switchResult.error)

  let switch = switchResult.get()
  defer:
    await switch.stop()
  let coordinator = newCoordinator(cfg.participants, cfg.configSignature())
  discard mountBase(switch, switch.rng)
  switch.mount(coordinator.protocol())
  let startResult = await startSwitch(switch)
  if startResult.isErr:
    error "Cannot start bootstrap switch", error = startResult.error
    startupFailure("switch_start", startResult.error)

  let addressesResult = switch.peerInfo.fullAddrs()
  if addressesResult.isErr or addressesResult.get().len == 0:
    error "Bootstrap has no advertised address"
    startupFailure("address", "Bootstrap has no advertised address")

  info "Bootstrap started",
    peerId = switch.peerInfo.peerId,
    addresses = addressesResult.get(),
    transport = cfg.transport,
    libp2pRevision = Libp2pRevision,
    participants = cfg.participants,
    timeoutSeconds = cfg.timeoutSeconds

  if started != nil and not started.finished():
    started.complete(addressesResult.get()[0])
  let shutdownSignal =
    if shutdownRequested == nil:
      waitShutdownSignal()
    else:
      shutdownRequested.wait()
  defer:
    await noCancel shutdownSignal.cancelAndWait()

  let deadline = Moment.now() + cfg.timeoutSeconds.seconds
  let monitorResult =
    await monitorCoordinator(coordinator, cfg, shutdownSignal, deadline)
  if monitorResult.isErr:
    recordFailure("bootstrap", coordinator.phase(), "coordination", monitorResult.error)
    error "Bootstrap coordination failed", reason = monitorResult.error
    return 1

  info "Bootstrap stopped after experiment completed"

  return 0

when isMainModule:
  try:
    quit(waitFor(main()))
  except CatchableError as exc:
    recordFailure("bootstrap", "unknown", "unexpected", exc.msg)
    error "Bootstrap fatal error", error = exc.msg
    quit(1)
