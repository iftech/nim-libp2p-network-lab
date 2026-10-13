# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import chronos, chronicles
import libp2p

import network_lab/common/[gossipsub_node]

logScope:
  topics = "network-lab"

proc main*(): Future[int] {.async: (raises: [CancelledError]).} =
  var switch: Switch
  defer:
    if switch != nil:
      await switch.stop()

  let
    rng = libp2p.newRng()
    topic = gossipTopic()
    timeoutSeconds =
      parsePositiveIntEnv("SELF_CHECK_TIMEOUT_SECS", DefaultSelfCheckTimeoutSeconds)

  let bootstrapResult = bootstrapAddress()
  if bootstrapResult.isErr:
    error "Invalid configuration", error = bootstrapResult.error
    return 1
  let bootstrap = bootstrapResult.get()

  let listenAddressResult = listenAddress()
  if listenAddressResult.isErr:
    error "Invalid configuration", error = listenAddressResult.error
    return 1

  let switchResult = buildSwitch(listenAddressResult.get())
  if switchResult.isErr:
    error "Invalid configuration", error = switchResult.error
    return 1
  switch = switchResult.get()

  let gossip =
    try:
      buildGossipSub(switch, rng)
    except InitializationError as e:
      error "Failed to initialize GossipSub", error = e.msg
      return 1

  gossip.subscribe(topic, nil)

  try:
    switch.mount(gossip)
  except LPError as e:
    error "Failed to mount GossipSub", error = e.msg
    return 1

  try:
    await switch.start()
  except LPError as e:
    error "Failed to start Switch", error = e.msg
    return 1

  let addresses = switch.peerInfo.fullAddrs()
  if addresses.isErr:
    error "Failed to determine GossipSub advertised addresses", error = $addresses.error
    return 1

  info "GossipSub node started",
    peerId = switch.peerInfo.peerId,
    addresses = addresses.get(),
    topic = topic,
    bootstrapPeerId = bootstrap.peerId,
    bootstrapAddress = bootstrap.transportAddress

  if not await waitForGossipPeer(switch, gossip, bootstrap, topic, timeoutSeconds):
    error "GossipSub self-check failed",
      topic = topic,
      timeoutSeconds = timeoutSeconds,
      bootstrapPeerId = bootstrap.peerId,
      bootstrapAddress = bootstrap.transportAddress,
      explanation =
        "No remote GossipSub peer subscribed to the topic before the deadline."
    return 1

  info "GossipSub self-check passed", topic = topic
  return 0

when isMainModule:
  quit(waitFor(main()))
