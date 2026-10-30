# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import std/[os, strutils]
from std/net import getPrimaryIPAddr, `$`
import results
import stew/byteutils
import libp2p

const
  Libp2pRevision* {.strdefine.} = "unknown"
  DefaultTopic* = "network-lab-regression"

type
  BootstrapAddress* = tuple[peerId: PeerId, transportAddress: MultiAddress]
  NodeConfig* = object
    transport*: string
    topic*: string
    bootstrapHost*: string
    index*, participants*, rounds*, threshold*, timeoutSeconds*, staggerMs*,
      bootstrapPort*, meshMinPeers*: int
    listen*: MultiAddress

  SwitchEnvValues* = object
    transport*: string
    maxConnections*: int
    announcedAddress*: Opt[MultiAddress]
    privateKey*: Opt[PrivateKey]

proc getEnvInt*(
    name: string, defaultValue, minValue, maxValue: int
): Result[int, string] =
  let raw = getEnv(name, $defaultValue)
  try:
    let value = parseInt(raw)
    if value < minValue or value > maxValue:
      return err(name & " out of range: " & raw)
    ok(value)
  except ValueError:
    err("Invalid " & name & ": " & raw)

proc getEnvPositiveInt*(name: string, defaultValue: int): Result[int, string] =
  getEnvInt(name, defaultValue, 1, int.high)

proc parseMultiAddress(name, value: string): Result[MultiAddress, string] =
  let addressResult = MultiAddress.init(value)
  if addressResult.isErr:
    return err("Invalid " & name & ": " & value & ": " & $addressResult.error)
  ok(addressResult.get())

proc getEnvListenAddress*(): Result[MultiAddress, string] =
  let transport = getEnv("TRANSPORT", "TCP").toUpperAscii()
  let host =
    try:
      $getPrimaryIPAddr()
    except CatchableError:
      "0.0.0.0"
  let defaultAddress =
    "/ip4/" & host & (if transport == "QUIC": "/udp/9000/quic-v1" else: "/tcp/9000")
  parseMultiAddress("LISTEN_ADDR", getEnv("LISTEN_ADDR", defaultAddress))

proc parseBootstrapAddress*(value: string): Result[BootstrapAddress, string] =
  let addressResult = parseFullAddress(value)
  if addressResult.isErr:
    return err($addressResult.error)
  ok(addressResult.get())

proc getEnvBootstrapAddress*(): Result[BootstrapAddress, string] =
  let raw = getEnv("BOOTSTRAP_ADDR")
  let addressResult = parseBootstrapAddress(raw)
  if addressResult.isErr:
    return err("Invalid BOOTSTRAP_ADDR: " & raw & ": " & addressResult.error)
  ok(addressResult.get())

proc getEnvGossipTopic*(): Result[string, string] =
  let topic = getEnv("GOSSIPSUB_TOPIC", DefaultTopic)
  if topic.len == 0 or '|' in topic:
    return err("GOSSIPSUB_TOPIC must not be empty or contain |")
  ok(topic)

proc loadEnvIntegerConfig(cfg: var NodeConfig, bootstrap: bool): Result[void, string] =
  template setInt(field, name, defaultValue, minValue, maxValue: untyped) =
    block:
      let valueResult = getEnvInt(name, defaultValue, minValue, maxValue)
      if valueResult.isErr:
        return err(valueResult.error)
      cfg.field = valueResult.get()

  setInt(bootstrapPort, "BOOTSTRAP_PORT", 9000, 1, 65535)
  setInt(participants, "PARTICIPANTS", 2, 2, 500)
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
  if not bootstrap:
    let offset = getEnvInt("NODE_INDEX_OFFSET", 0, 0, cfg.participants - 1)
    if offset.isErr:
      return err(offset.error)
    cfg.index += offset.get()
    if cfg.index >= cfg.participants:
      return err("NODE_INDEX + NODE_INDEX_OFFSET must be less than PARTICIPANTS")
  setInt(rounds, "MESSAGE_ROUNDS", 3, 1, 100)
  setInt(threshold, "DELIVERY_PERCENT", 99, 1, 100)
  setInt(timeoutSeconds, "SELF_CHECK_TIMEOUT_SECS", 900, 1, 3600)
  setInt(staggerMs, "STARTUP_JITTER_STEP_MS", 50, 0, 10000)
  # Zero selects GossipSub's dLow, capped by the number of remote participants.
  setInt(meshMinPeers, "MESH_MIN_PEERS", 0, 0, cfg.participants - 1)
  ok()

proc loadEnvConfig*(bootstrap: bool): Result[NodeConfig, string] =
  var cfg: NodeConfig
  cfg.transport = getEnv("TRANSPORT", "TCP").toUpperAscii()
  if cfg.transport notin ["TCP", "QUIC"] and not (bootstrap and cfg.transport == "BOTH"):
    return err(
      "TRANSPORT must be TCP or QUIC (bootstrap also accepts BOTH), got: " &
        cfg.transport
    )
  let topicResult = getEnvGossipTopic()
  if topicResult.isErr:
    return err(topicResult.error)
  cfg.topic = topicResult.get()
  cfg.bootstrapHost = getEnv("BOOTSTRAP_HOST", "bootstrap-0.nodes")
  if cfg.bootstrapHost.len == 0:
    return err("BOOTSTRAP_HOST must not be empty")

  let integerConfigResult = loadEnvIntegerConfig(cfg, bootstrap)
  if integerConfigResult.isErr:
    return err(integerConfigResult.error)
  let listenAddressResult = getEnvListenAddress()
  if listenAddressResult.isErr:
    return err(listenAddressResult.error)
  cfg.listen = listenAddressResult.get()
  let addressText = $cfg.listen
  if (cfg.transport in ["TCP", "BOTH"] and "/tcp/" notin addressText) or
      (cfg.transport == "QUIC" and "/quic-v1" notin addressText):
    return err("LISTEN_ADDR does not match TRANSPORT: " & addressText)
  ok(cfg)

proc loadEnvSwitchValues*(): Result[SwitchEnvValues, string] =
  var values: SwitchEnvValues
  values.transport = getEnv("TRANSPORT", "TCP").toUpperAscii()
  if values.transport notin ["TCP", "QUIC", "BOTH"]:
    return err("TRANSPORT must be TCP, QUIC or BOTH")
  let maxConnectionsResult = getEnvInt("MAX_CONNECTIONS", 250, 1, 10000)
  if maxConnectionsResult.isErr:
    return err(maxConnectionsResult.error)
  values.maxConnections = maxConnectionsResult.get()

  let announcedAddress = getEnv("ANNOUNCE_ADDR")
  if announcedAddress.len > 0:
    let addressResult = parseMultiAddress("ANNOUNCE_ADDR", announcedAddress)
    if addressResult.isErr:
      return err(addressResult.error)
    values.announcedAddress = Opt.some(addressResult.get())

  let privateKeyHex = getEnv("PRIVATE_KEY")
  if privateKeyHex.len > 0:
    try:
      let keyResult = PrivateKey.init(hexToSeqByte(privateKeyHex))
      if keyResult.isErr:
        return err("Invalid PRIVATE_KEY: " & $keyResult.error)
      values.privateKey = Opt.some(keyResult.get())
    except CatchableError as exc:
      return err("Invalid PRIVATE_KEY: " & exc.msg)
  ok(values)
