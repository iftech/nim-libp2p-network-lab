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
      timeoutSeconds = parsePositiveIntEnv(
        "SELF_CHECK_TIMEOUT_SECS", DefaultSelfCheckTimeoutSeconds
      )
      bootstrap = bootstrapAddress()
    switch = buildSwitch(listenAddress())

    let gossip = buildGossipSub(switch, rng)
    gossip.subscribe(topic, nil)
    switch.mount(gossip)
    await switch.start()

    info "GossipSub node started",
      peerId = switch.peerInfo.peerId,
      addresses = switch.peerInfo.fullAddrs.tryGet(),
      topic = topic,
      bootstrap = $bootstrap

    if not await waitForGossipPeer(switch, gossip, bootstrap, topic, timeoutSeconds):
      error "GossipSub self-check failed: no remote GossipSub peer connected before deadline",
        topic = topic,
        timeoutSeconds = timeoutSeconds,
        bootstrap = $bootstrap
      return 1

    info "GossipSub self-check passed", topic = topic
    await waitShutdownSignal()
    return 0
  except CatchableError as exc:
    error "GossipSub node failed", error = exc.msg
    return 1
  finally:
    if switch != nil:
      await switch.stop()

quit(waitFor(main()))
