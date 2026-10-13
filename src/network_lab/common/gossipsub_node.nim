import std/[os, strutils, tables]

import chronos, chronicles
import stew/byteutils
import libp2p

const
  DefaultListenAddress* = "/ip4/0.0.0.0/tcp/9000"
  DefaultTopic* = "network-lab"
  DefaultSelfCheckTimeoutSeconds* = 120

proc parsePositiveIntEnv*(name: string, defaultValue: int): int =
  let value = getEnv(name)
  if value.len == 0:
    return defaultValue

  try:
    result = parseInt(value)
    if result <= 0:
      raise newException(ValueError, "must be greater than zero")
  except ValueError:
    warn "Invalid environment value; using default",
      name = name, value = value, defaultValue = defaultValue
    result = defaultValue

proc listenAddress*(): MultiAddress =
  let value = getEnv("LISTEN_ADDR", DefaultListenAddress)
  MultiAddress.init(value).tryGet()

proc bootstrapAddress*(): MultiAddress =
  let value = getEnv("BOOTSTRAP_ADDR")
  if value.len == 0:
    raise newException(ValueError, "BOOTSTRAP_ADDR is required")
  MultiAddress.init(value).tryGet()

proc gossipTopic*(): string =
  getEnv("GOSSIPSUB_TOPIC", DefaultTopic)

proc buildSwitch*(address: MultiAddress): Switch =
  var builder = SwitchBuilder
    .new()
    .withAddress(address)
    .withTcpTransport()
    .withNoise()
    .withYamux()

  let announcedAddress = getEnv("ANNOUNCE_ADDR")
  if announcedAddress.len > 0:
    builder = builder.withAnnouncedAddress(MultiAddress.init(announcedAddress).tryGet())

  let privateKeyHex = getEnv("PRIVATE_KEY")
  if privateKeyHex.len > 0:
    try:
      let privateKey = PrivateKey.init(hexToSeqByte(privateKeyHex)).tryGet()
      builder = builder.withPrivateKey(privateKey)
    except CatchableError as exc:
      raise newException(ValueError, "Invalid PRIVATE_KEY: " & exc.msg)

  builder.build()

proc buildGossipSub*(switch: Switch, rng: Rng): GossipSub =
  GossipSub.init(switch = switch, triggerSelf = true, rng = rng)

proc hasRemoteGossipPeer*(gossip: GossipSub, topic: string): bool =
  ## `gossipsub` tracks peers that announced a subscription to `topic`.
  ## This is a protocol-level check, not just a TCP connection check.
  gossip.gossipsub.getOrDefault(topic).len > 0

proc waitForGossipPeer*(
    switch: Switch,
    gossip: GossipSub,
    bootstrap: MultiAddress,
    topic: string,
    timeoutSeconds: int,
): Future[bool] {.async.} =
  ## Dial the bootstrap periodically and wait until a remote GossipSub peer has
  ## subscribed to the configured topic. Returns false on deadline expiry.
  for attempt in 0 ..< timeoutSeconds:
    if gossip.hasRemoteGossipPeer(topic):
      return true

    if attempt mod 5 == 0:
      try:
        let peerId = await switch.connect(bootstrap)
        debug "Connected to bootstrap", peerId = peerId
      except CatchableError as exc:
        debug "Bootstrap dial failed; will retry", error = exc.msg

    await sleepAsync(1.seconds)

  gossip.hasRemoteGossipPeer(topic)
