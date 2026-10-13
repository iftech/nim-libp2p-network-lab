# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import std/[os, strutils, tables]

import chronos, chronicles
import results
import stew/byteutils
import libp2p

const
  DefaultListenAddress* = "/ip4/0.0.0.0/tcp/9000"
  DefaultTopic* = "network-lab"
  DefaultSelfCheckTimeoutSeconds* = 120

type BootstrapAddress* = tuple[peerId: PeerId, transportAddress: MultiAddress]
type ConfigResult*[T] = Result[T, string]

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
    result = defaultValue

proc parseMultiAddress(name, value: string): ConfigResult[MultiAddress] =
  let parsed = MultiAddress.init(value)
  if parsed.isErr:
    return ConfigResult[MultiAddress].err(
      "Invalid " & name & " multiaddress '" & value & "': " & $parsed.error
    )
  ConfigResult[MultiAddress].ok(parsed.get())

proc listenAddress*(): ConfigResult[MultiAddress] =
  let value = getEnv("LISTEN_ADDR", DefaultListenAddress)
  parseMultiAddress("LISTEN_ADDR", value)

proc parseBootstrapAddress*(value: string): MaResult[BootstrapAddress] =
  ## Parse a complete dial address and require a terminal `/p2p/<peer-id>`.
  parseFullAddress(value)

proc bootstrapAddress*(): ConfigResult[BootstrapAddress] =
  let value = getEnv("BOOTSTRAP_ADDR")
  if value.len == 0:
    return ConfigResult[BootstrapAddress].err(
      "Missing BOOTSTRAP_ADDR; set it to a full multiaddress ending in " &
        "/p2p/<peer-id>."
    )
  let parsed = parseBootstrapAddress(value)
  if parsed.isErr:
    return ConfigResult[BootstrapAddress].err(
      "Invalid BOOTSTRAP_ADDR '" & value & "': " & $parsed.error
    )
  ConfigResult[BootstrapAddress].ok(parsed.get())

proc gossipTopic*(): string =
  getEnv("GOSSIPSUB_TOPIC", DefaultTopic)

proc buildSwitch*(address: MultiAddress): ConfigResult[Switch] {.raises: [].} =
  var builder =
    SwitchBuilder.new().withAddress(address).withTcpTransport().withNoise().withYamux()

  let announcedAddress = getEnv("ANNOUNCE_ADDR")
  if announcedAddress.len > 0:
    let parsedAddress = parseMultiAddress("ANNOUNCE_ADDR", announcedAddress)
    if parsedAddress.isErr:
      return ConfigResult[Switch].err(parsedAddress.error)
    builder = builder.withAnnouncedAddress(parsedAddress.get())

  let privateKeyHex = getEnv("PRIVATE_KEY")
  if privateKeyHex.len > 0:
    try:
      let privateKeyResult = PrivateKey.init(hexToSeqByte(privateKeyHex))
      if privateKeyResult.isErr:
        return
          ConfigResult[Switch].err("Invalid PRIVATE_KEY: " & $privateKeyResult.error)
      let privateKey = privateKeyResult.get()
      builder = builder.withPrivateKey(privateKey)
    except CatchableError as e:
      return ConfigResult[Switch].err("Invalid PRIVATE_KEY: " & e.msg)

  try:
    ConfigResult[Switch].ok(builder.build())
  except LPError as e:
    ConfigResult[Switch].err("Failed to build switch: " & e.msg)

proc buildGossipSub*(switch: Switch, rng: Rng): GossipSub =
  GossipSub.init(switch = switch, triggerSelf = true, rng = rng)

proc hasRemoteGossipPeer*(gossip: GossipSub, topic: string): bool =
  ## `gossipsub` tracks peers that announced a subscription to `topic`.
  ## This is a protocol-level check, not just a TCP connection check.
  gossip.gossipsub.getOrDefault(topic).len > 0

proc waitForGossipPeer*(
    switch: Switch,
    gossip: GossipSub,
    bootstrap: BootstrapAddress,
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
        await switch.connect(bootstrap.peerId, @[bootstrap.transportAddress])
        debug "Connected to bootstrap", peerId = bootstrap.peerId
      except CancelledError as e:
        raise e
      except CatchableError as e:
        debug "Bootstrap dial failed; retrying", error = e.msg

    await sleepAsync(1.seconds)

  gossip.hasRemoteGossipPeer(topic)
