# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import std/[sets, strutils, tables]
import chronos, chronicles, results
import stew/byteutils
import libp2p

const ControlCodec* = "/network-lab/regression/1.0.0"

type
  Coordinator* = ref object
    expected*: int
    signature: string
    peers: Table[int, PeerId]
    ready*, published*, verified*: HashSet[int]
    failure*: string

  ControlCommand = enum
    register = "register"
    ready = "ready"
    published = "published"
    verified = "verified"
    failed = "failed"

  ControlRequest = object
    command: ControlCommand
    index: int

proc newCoordinator*(expected: int, signature: string): Coordinator =
  Coordinator(expected: expected, signature: signature)

proc registered*(c: Coordinator): int =
  c.peers.len

proc phase*(c: Coordinator): string =
  if c.failure.len > 0:
    "failed"
  elif c.verified.len == c.expected:
    "complete"
  elif c.published.len == c.expected:
    "verify"
  elif c.ready.len == c.expected:
    "publish"
  else:
    "ready"

proc parseControlRequest(
    raw, signature: string, expected: int
): Result[ControlRequest, string] =
  let parts = raw.split('|')
  if parts.len != 3 or parts[2] != signature:
    return err("invalid control request")
  var index: int
  try:
    index = parseInt(parts[1])
  except ValueError:
    return err("invalid participant index")
  if index < 0 or index >= expected:
    return err("participant index out of range")
  try:
    ok(ControlRequest(command: parseEnum[ControlCommand](parts[0]), index: index))
  except ValueError:
    err("unknown control request")

proc applyControlRequest(
    c: Coordinator, peer: PeerId, request: ControlRequest
): Result[string, string] =
  let index = request.index
  if c.peers.hasKey(index) and c.peers[index] != peer:
    return err("participant index already belongs to another peer")
  for existingIndex, existingPeer in c.peers:
    if existingPeer == peer and existingIndex != index:
      return err("peer already registered with another index")

  case request.command
  of register:
    discard
  of ready:
    c.ready.incl(index)
  of published:
    if c.ready.len != c.expected:
      return err("published before all participants were ready")
    c.published.incl(index)
  of verified:
    if c.published.len != c.expected:
      return err("verified before all participants published")
    c.verified.incl(index)
  of failed:
    c.failure = "participant " & $index & " reported failure"
    error "Participant reported failure", index = index, peerId = peer
  c.peers[index] = peer
  ok(c.phase())

proc handleControlStream(
    c: Coordinator, stream: Stream
) {.async: (raises: [CancelledError]).} =
  try:
    let raw = string.fromBytes(await stream.readLp(1024))
    let requestResult = parseControlRequest(raw, c.signature, c.expected)
    if requestResult.isErr:
      warn "Rejected control request",
        peerId = stream.peerId, error = requestResult.error
      await stream.writeLp("failed")
      return

    let responseResult = applyControlRequest(c, stream.peerId, requestResult.get())
    if responseResult.isErr:
      c.failure = "control protocol error: " & responseResult.error
      error "Control protocol error",
        peerId = stream.peerId, error = responseResult.error
      await stream.writeLp("failed")
      return
    await stream.writeLp(responseResult.get())
  except CancelledError as exc:
    raise exc
  except LPStreamError as exc:
    warn "Control stream failed", peerId = stream.peerId, error = exc.msg
  except CatchableError as exc:
    c.failure = "control protocol error: " & exc.msg
    error "Control protocol error", peerId = stream.peerId, error = exc.msg
    try:
      await stream.writeLp("failed")
    except CancelledError as exc:
      raise exc
    except CatchableError:
      discard
  finally:
    await stream.close()

proc protocol*(c: Coordinator): LPProtocol =
  proc handle(stream: Stream, proto: string) {.async: (raises: [CancelledError]).} =
    await handleControlStream(c, stream)

  LPProtocol.new(@[ControlCodec], handle)

proc exchange*(
    switch: Switch, peer: PeerId, command: string, index: int, signature: string
): Future[Result[string, string]] {.async.} =
  var stream: Stream
  try:
    stream = await switch.dial(peer, ControlCodec)
    await stream.writeLp(command & "|" & $index & "|" & signature)
    return ok(string.fromBytes(await stream.readLp(1024)))
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    return err(exc.msg)
  finally:
    if stream != nil:
      await stream.close()
