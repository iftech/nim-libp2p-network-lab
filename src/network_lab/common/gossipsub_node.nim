# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import std/[hashes, options, os, strutils, tables]
from std/net import getPrimaryIPAddr
import chronos, results
import stew/byteutils
import libp2p
import libp2p/protocols/[kademlia, ping]
import libp2p/protocols/pubsub/rpc/messages

const
  Libp2pRevision* {.strdefine.} = "unknown"
  DefaultTopic* = "network-lab-regression"
  DefaultSelfCheckTimeoutSeconds* = 900

type
  ConfigResult*[T] = Result[T, string]
  BootstrapAddress* = tuple[peerId: PeerId, transportAddress: MultiAddress]
  NodeConfig* = object
    transport*: string
    topic*: string
    bootstrapHost*: string
    index*, participants*, rounds*, threshold*, timeoutSeconds*, staggerMs*,
      bootstrapPort*: int
    listen*: MultiAddress

proc requiredInt(
    name: string, defaultValue, minValue, maxValue: int
): ConfigResult[int] =
  let raw = getEnv(name, $defaultValue)
  try:
    let value = parseInt(raw)
    if value < minValue or value > maxValue:
      return ConfigResult[int].err(name & " out of range: " & raw)
    ConfigResult[int].ok(value)
  except ValueError:
    ConfigResult[int].err("Invalid " & name & ": " & raw)

proc parsePositiveIntEnv*(name: string, defaultValue: int): int =
  let valueResult = requiredInt(name, defaultValue, 1, int.high)
  if valueResult.isOk:
    valueResult.get()
  else:
    defaultValue

proc getEnvSeqMultiaddress*(name: string): Result[seq[MultiAddress], string] =
  let value = getEnv(name)
  if value.len == 0:
    return Result[seq[MultiAddress], string].ok(@[])
  let addressResult = MultiAddress.init(value)
  if addressResult.isErr:
    return Result[seq[MultiAddress], string].err(
      "Invalid " & name & ": " & value & ": " & $addressResult.error
    )
  Result[seq[MultiAddress], string].ok(@[addressResult.get()])

proc parseMultiAddress(name, value: string): ConfigResult[MultiAddress] =
  let addressResult = MultiAddress.init(value)
  if addressResult.isErr:
    return ConfigResult[MultiAddress].err(
      "Invalid " & name & ": " & value & ": " & $addressResult.error
    )
  ConfigResult[MultiAddress].ok(addressResult.get())

proc listenAddress*(): ConfigResult[MultiAddress] =
  let transport = getEnv("TRANSPORT", "TCP").toUpperAscii()
  let host =
    try:
      $getPrimaryIPAddr()
    except CatchableError:
      "0.0.0.0"
  let defaultAddress =
    "/ip4/" & host & (if transport == "QUIC": "/udp/9000/quic-v1" else: "/tcp/9000")
  parseMultiAddress("LISTEN_ADDR", getEnv("LISTEN_ADDR", defaultAddress))

proc parseBootstrapAddress*(value: string): MaResult[BootstrapAddress] =
  parseFullAddress(value)

proc bootstrapAddress*(): ConfigResult[BootstrapAddress] =
  let raw = getEnv("BOOTSTRAP_ADDR")
  let bootstrapResult = parseBootstrapAddress(raw)
  if bootstrapResult.isErr:
    return ConfigResult[BootstrapAddress].err("Invalid BOOTSTRAP_ADDR: " & raw)
  ConfigResult[BootstrapAddress].ok(bootstrapResult.get())

proc gossipTopic*(): string =
  getEnv("GOSSIPSUB_TOPIC", DefaultTopic)

proc loadIntegerConfig(cfg: var NodeConfig, bootstrap: bool): ConfigResult[void] =
  template setInt(field, name, defaultValue, minValue, maxValue: untyped) =
    block:
      let valueResult = requiredInt(name, defaultValue, minValue, maxValue)
      if valueResult.isErr:
        return ConfigResult[void].err(valueResult.error)
      cfg.field = valueResult.get()

  setInt(bootstrapPort, "BOOTSTRAP_PORT", 9000, 1, 65535)
  setInt(participants, "PARTICIPANTS", 2, 2, 499)
  setInt(
    index,
    "NODE_INDEX",
    0,
    0,
    if bootstrap:
      0
    else:
      cfg.participants - 1,
  )
  setInt(rounds, "MESSAGE_ROUNDS", 3, 1, 100)
  setInt(threshold, "DELIVERY_PERCENT", 99, 1, 100)
  setInt(
    timeoutSeconds, "SELF_CHECK_TIMEOUT_SECS", DefaultSelfCheckTimeoutSeconds, 1, 3600
  )
  setInt(staggerMs, "STARTUP_JITTER_STEP_MS", 50, 0, 10000)
  ConfigResult[void].ok()

proc loadConfig*(bootstrap: bool): ConfigResult[NodeConfig] =
  var cfg: NodeConfig
  cfg.transport = getEnv("TRANSPORT", "TCP").toUpperAscii()
  if cfg.transport notin ["TCP", "QUIC"]:
    return ConfigResult[NodeConfig].err(
      "TRANSPORT must be TCP or QUIC, got: " & cfg.transport
    )
  cfg.topic = gossipTopic()
  if cfg.topic.len == 0 or '|' in cfg.topic:
    return
      ConfigResult[NodeConfig].err("GOSSIPSUB_TOPIC must not be empty or contain |")
  cfg.bootstrapHost = getEnv("BOOTSTRAP_HOST", "bootstrap-0.nodes")
  if cfg.bootstrapHost.len == 0:
    return ConfigResult[NodeConfig].err("BOOTSTRAP_HOST must not be empty")
  let integerConfigResult = loadIntegerConfig(cfg, bootstrap)
  if integerConfigResult.isErr:
    return ConfigResult[NodeConfig].err(integerConfigResult.error)
  let addressResult = listenAddress()
  if addressResult.isErr:
    return ConfigResult[NodeConfig].err(addressResult.error)
  cfg.listen = addressResult.get()
  let addrText = $cfg.listen
  if (cfg.transport == "TCP" and "/tcp/" notin addrText) or
      (cfg.transport == "QUIC" and "/quic-v1" notin addrText):
    return
      ConfigResult[NodeConfig].err("LISTEN_ADDR does not match TRANSPORT: " & addrText)
  ConfigResult[NodeConfig].ok(cfg)

proc announcedAddressEnv(): ConfigResult[Option[MultiAddress]] =
  let announcedAddress = getEnv("ANNOUNCE_ADDR")
  if announcedAddress.len == 0:
    return ConfigResult[Option[MultiAddress]].ok(none(MultiAddress))
  let addressResult = parseMultiAddress("ANNOUNCE_ADDR", announcedAddress)
  if addressResult.isErr:
    return ConfigResult[Option[MultiAddress]].err(addressResult.error)
  ConfigResult[Option[MultiAddress]].ok(some(addressResult.get()))

proc privateKeyEnv(): ConfigResult[Option[PrivateKey]] =
  let privateKeyHex = getEnv("PRIVATE_KEY")
  if privateKeyHex.len == 0:
    return ConfigResult[Option[PrivateKey]].ok(none(PrivateKey))
  try:
    let keyResult = PrivateKey.init(hexToSeqByte(privateKeyHex))
    if keyResult.isErr:
      return ConfigResult[Option[PrivateKey]].err("Invalid PRIVATE_KEY: " & $keyResult.error)
    ConfigResult[Option[PrivateKey]].ok(some(keyResult.get()))
  except CatchableError as exc:
    ConfigResult[Option[PrivateKey]].err("Invalid PRIVATE_KEY: " & exc.msg)

proc buildSwitch*(address: MultiAddress): ConfigResult[Switch] {.raises: [].} =
  let transport = getEnv("TRANSPORT", "TCP").toUpperAscii()
  if transport notin ["TCP", "QUIC"]:
    return ConfigResult[Switch].err("TRANSPORT must be TCP or QUIC")
  let maxConnectionsResult = requiredInt("MAX_CONNECTIONS", 250, 1, 10000)
  if maxConnectionsResult.isErr:
    return ConfigResult[Switch].err(maxConnectionsResult.error)
  var builder =
    SwitchBuilder.new().withAddress(address).withMaxConnections(maxConnectionsResult.get())
  if transport == "TCP":
    builder = builder.withTcpTransport().withNoise().withMplex()
  else:
    builder = builder.withQuicTransport()

  let announcedAddressResult = announcedAddressEnv()
  if announcedAddressResult.isErr:
    return ConfigResult[Switch].err(announcedAddressResult.error)
  if announcedAddressResult.get().isSome:
    builder = builder.withAnnouncedAddress(announcedAddressResult.get().get())

  let privateKeyResult = privateKeyEnv()
  if privateKeyResult.isErr:
    return ConfigResult[Switch].err(privateKeyResult.error)
  if privateKeyResult.get().isSome:
    builder = builder.withPrivateKey(privateKeyResult.get().get())
  try:
    ConfigResult[Switch].ok(builder.build())
  except LPError as exc:
    ConfigResult[Switch].err("Failed to build switch: " & exc.msg)

proc startSwitch*(switch: Switch): Future[ConfigResult[void]] {.async.} =
  try:
    await switch.start()
    return ConfigResult[void].ok()
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    return ConfigResult[void].err("Failed to start switch: " & exc.msg)

proc mountBase*(switch: Switch, rng: Rng): tuple[kad: KadDHT, ping: Ping] =
  let ping = Ping.new(rng = rng)
  let kad = KadDHT.new(switch, rng = rng)
  switch.mount(ping)
  switch.mount(kad)
  (kad, ping)

proc messageId(msg: messages.Message): Result[MessageId, ValidationResult] =
  ok(($msg.data.hash).toBytes())

proc buildGossipSub*(switch: Switch, rng: Rng): GossipSub =
  result = GossipSub.init(
    switch = switch,
    triggerSelf = true,
    anonymize = true,
    verifySignature = false,
    msgIdProvider = messageId,
    rng = rng,
  )
  result.parameters.floodPublish = true
  result.parameters.opportunisticGraftThreshold = -10000
  result.parameters.heartbeatInterval = 1.seconds
  result.parameters.pruneBackoff = 60.seconds
  result.parameters.gossipFactor = 0.25
  result.parameters.d = 6
  result.parameters.dLow = 4
  result.parameters.dHigh = 8
  result.parameters.dScore = 6
  result.parameters.dOut = 3
  result.parameters.dLazy = 6

proc remotePeerCount*(gossip: GossipSub, topic: string): int =
  gossip.gossipsub.getOrDefault(topic).len

proc configSignature*(cfg: NodeConfig): string =
  cfg.transport & "," & cfg.topic & "," & $cfg.participants & "," & $cfg.rounds & "," &
    $cfg.threshold & "," & Libp2pRevision
