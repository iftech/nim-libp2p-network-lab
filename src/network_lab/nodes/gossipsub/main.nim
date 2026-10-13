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
    timeoutSeconds =
      parsePositiveIntEnv("SELF_CHECK_TIMEOUT_SECS", DefaultSelfCheckTimeoutSeconds)
    bootstrap = bootstrapAddress()
  switch = buildSwitch(listenAddress())

  let gossip = buildGossipSub(switch, rng)
  gossip.subscribe(topic, nil)
  switch.mount(gossip)
  await switch.start()

  let addresses = switch.peerInfo.fullAddrs()
  if addresses.isErr:
    error "GossipSub node could not determine its advertised addresses",
      reason = $addresses.error
    return 1

  info "GossipSub node started",
    peerId = switch.peerInfo.peerId,
    addresses = addresses.get(),
    topic = topic,
    bootstrap = $bootstrap

  if not await waitForGossipPeer(switch, gossip, bootstrap, topic, timeoutSeconds):
    error "GossipSub self-check failed: no remote GossipSub peer connected before deadline",
      topic = topic, timeoutSeconds = timeoutSeconds, bootstrap = $bootstrap
    return 1

  info "GossipSub self-check passed", topic = topic
  await waitShutdownSignal()
  return 0

quit(waitFor(main()))
