import chronos, chronicles
import libp2p

import network_lab/common/[gossipsub_node, shutdown]

logScope:
  topics = "network-lab"

proc main(): Future[int] {.async.} =
  var switch: Switch

  try:
    let
      rng = libp2p.newRng()
      topic = gossipTopic()
    switch = buildSwitch(listenAddress())

    let gossip = buildGossipSub(switch, rng)
    gossip.subscribe(topic, nil)
    switch.mount(gossip)
    await switch.start()

    info "Bootstrap node started",
      peerId = switch.peerInfo.peerId,
      addresses = switch.peerInfo.fullAddrs.tryGet(),
      topic = topic

    await waitShutdownSignal()
    return 0
  except CatchableError as exc:
    error "Bootstrap node failed", error = exc.msg
    return 1
  finally:
    if switch != nil:
      await switch.stop()

quit(waitFor(main()))
