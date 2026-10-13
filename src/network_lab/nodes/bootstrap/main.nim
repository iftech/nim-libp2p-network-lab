import chronos, chronicles
import libp2p

import network_lab/common/[gossipsub_node, shutdown]

logScope:
  topics = "network-lab"

proc main(): Future[int] {.async.} =
  var switch: Switch
  defer:
    if switch != nil:
      await switch.stop()

  let
    rng = libp2p.newRng()
    topic = gossipTopic()
  switch = buildSwitch(listenAddress())

  let gossip = buildGossipSub(switch, rng)
  gossip.subscribe(topic, nil)
  switch.mount(gossip)
  await switch.start()

  let addresses = switch.peerInfo.fullAddrs()
  if addresses.isErr:
    error "Bootstrap node could not determine its advertised addresses",
      reason = $addresses.error
    return 1

  info "Bootstrap node started",
    peerId = switch.peerInfo.peerId, addresses = addresses.get(), topic = topic

  await waitShutdownSignal()
  return 0

quit(waitFor(main()))
