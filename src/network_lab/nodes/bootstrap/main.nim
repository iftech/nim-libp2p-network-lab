# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import chronos, chronicles
import libp2p

import network_lab/common/[gossipsub_node, shutdown]

logScope:
  topics = "network-lab"

proc main*(
    started: Future[MultiAddress] = nil, shutdownRequested: AsyncEvent = nil
): Future[int] {.async: (raises: [CancelledError]).} =
  ## Run the bootstrap node. Optional futures allow an in-process caller to
  ## discover its address and request shutdown without installing OS signals.
  var switch: Switch
  defer:
    if switch != nil:
      await switch.stop()

  let
    rng = libp2p.newRng()
    topic = gossipTopic()
  switch = buildSwitch(listenAddress())

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
    error "Failed to determine bootstrap advertised addresses", error = $addresses.error
    return 1

  let fullAddresses = addresses.get()
  info "Bootstrap node started",
    peerId = switch.peerInfo.peerId, addresses = fullAddresses, topic = topic

  if started != nil and not started.finished():
    if fullAddresses.len == 0:
      error "Bootstrap node has no advertised address"
      return 1
    started.complete(fullAddresses[0])

  if shutdownRequested == nil:
    await waitShutdownSignal()
  else:
    await shutdownRequested.wait()
  return 0

when isMainModule:
  quit(waitFor(main()))
