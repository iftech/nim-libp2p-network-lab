# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import std/[hashes, strutils, tables]
import chronos, results
import stew/byteutils
import libp2p
import libp2p/protocols/[kademlia, ping]
import libp2p/protocols/pubsub/rpc/messages
import libp2p/transports/[transport, tcptransport, quictransport]
import ./env_values
import ./dial_only_transport

proc buildSwitch*(address: MultiAddress): Result[Switch, string] {.raises: [].} =
  let valuesResult = loadEnvSwitchValues()
  if valuesResult.isErr:
    return Result[Switch, string].err(valuesResult.error)
  let values = valuesResult.get()

  var addresses = @[address]
  if values.transport == "BOTH":
    # The coordinator accepts both cohorts on the same TCP/UDP port number.
    if "/tcp/" notin $address:
      return err("TRANSPORT=BOTH requires a TCP LISTEN_ADDR")
    let quicAddress =
      MultiAddress.init(($address).replace("/tcp/", "/udp/") & "/quic-v1")
    if quicAddress.isErr:
      return err("Cannot derive QUIC listen address from LISTEN_ADDR")
    addresses.add(quicAddress.get())
  # Participants listen on their selected transport, but can dial either kind
  # of peer so TCP and QUIC listeners form a single mesh.
  var builder = SwitchBuilder
    .new()
    .withAddresses(addresses)
    .withMaxConnections(values.maxConnections)
    .withNoise()
    .withMplex()
  if values.transport == "QUIC":
    builder = builder.withQuicTransport().withTransport(
        proc(config: TransportConfig): Transport =
          dialOnly(TcpTransport.new({}, config.upgr))
      )
  elif values.transport == "TCP":
    builder = builder.withTcpTransport().withTransport(
        proc(config: TransportConfig): Transport =
          dialOnly(
            QuicTransport.new(
              config.upgr, config.privateKey, config.rng, config.connManager
            )
          )
      )
  else:
    builder = builder.withTcpTransport().withQuicTransport()
  if values.announcedAddress.isSome:
    builder = builder.withAnnouncedAddress(values.announcedAddress.get())
  if values.privateKey.isSome:
    builder = builder.withPrivateKey(values.privateKey.get())

  try:
    Result[Switch, string].ok(builder.build())
  except LPError as exc:
    Result[Switch, string].err("Failed to build switch: " & exc.msg)

proc startSwitch*(
    switch: Switch
): Future[Result[void, string]] {.async: (raises: [CancelledError]).} =
  try:
    await switch.start()
    return Result[void, string].ok()
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    return Result[void, string].err("Failed to start switch: " & exc.msg)

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
  cfg.topic & "," & $cfg.participants & "," & $cfg.rounds & "," & $cfg.threshold & "," &
    Libp2pRevision
