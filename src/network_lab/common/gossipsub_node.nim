# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

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
  except ValueError:
    warn "Invalid positive integer environment value; using default",
      name, value, defaultValue
    return defaultValue

  if result <= 0:
    warn "Positive integer environment value must be greater than zero; using default",
      name, value, defaultValue

proc multiAddressOrExit(name, value: string): MultiAddress =
  let parsed = MultiAddress.init(value)
  if parsed.isErr:
    error "Invalid multiaddress", name, value, error = $parsed.error
    quit(1)
  parsed.get()

proc listenAddress*(): MultiAddress =
  let value = getEnv("LISTEN_ADDR", DefaultListenAddress)
  multiAddressOrExit("LISTEN_ADDR", value)

proc bootstrapAddress*(): MultiAddress =
  let value = getEnv("BOOTSTRAP_ADDR")
  if value.len == 0:
    error "Missing bootstrap address",
      name = "BOOTSTRAP_ADDR",
      explanation =
        "Set BOOTSTRAP_ADDR to a full multiaddress ending in /p2p/<peer-id>."
    quit(1)
  multiAddressOrExit("BOOTSTRAP_ADDR", value)

proc gossipTopic*(): string =
  getEnv("GOSSIPSUB_TOPIC", DefaultTopic)

proc buildSwitch*(address: MultiAddress): Switch {.raises: [].} =
  var builder =
    SwitchBuilder.new().withAddress(address).withTcpTransport().withNoise().withYamux()

  let announcedAddress = getEnv("ANNOUNCE_ADDR")
  if announcedAddress.len > 0:
    builder = builder.withAnnouncedAddress(
      multiAddressOrExit("ANNOUNCE_ADDR", announcedAddress)
    )

  let privateKeyHex = getEnv("PRIVATE_KEY")
  if privateKeyHex.len > 0:
    try:
      let privateKeyResult = PrivateKey.init(hexToSeqByte(privateKeyHex))
      if privateKeyResult.isErr:
        error "Invalid private key", error = $privateKeyResult.error
        quit(1)
      let privateKey = privateKeyResult.get()
      builder = builder.withPrivateKey(privateKey)
    except CatchableError as e:
      error "Invalid private key", error = e.msg
      quit(1)

  try:
    builder.build()
  except LPError as e:
    error "Failed to build switch", error = e.msg
    quit(1)

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
): Future[bool] {.async: (raises: [CancelledError]).} =
  ## Dial the bootstrap periodically and wait until a remote GossipSub peer has
  ## subscribed to the configured topic. Returns false on deadline expiry.
  for attempt in 0 ..< timeoutSeconds:
    if gossip.hasRemoteGossipPeer(topic):
      return true

    if attempt mod 5 == 0:
      try:
        let conn = await switch.connect(bootstrap)
        debug "Connected to bootstrap", peerId = conn.peerId
      except CancelledError as e:
        raise e
      except CatchableError as e:
        debug "Bootstrap dial failed; retrying", error = e.msg

    await sleepAsync(1.seconds)

  gossip.hasRemoteGossipPeer(topic)
