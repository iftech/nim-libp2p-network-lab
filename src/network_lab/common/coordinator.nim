# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import std/[sets, strutils, tables]
import chronos, chronicles
import stew/byteutils
import libp2p

const ControlCodec* = "/network-lab/regression/1.0.0"

type Coordinator* = ref object
  expected*: int
  signature: string
  peers: Table[int, PeerId]
  ready*, published*, verified*: HashSet[int]
  failure*: string

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

proc protocol*(c: Coordinator): LPProtocol =
  proc handle(stream: Stream, proto: string) {.async: (raises: [CancelledError]).} =
    try:
      let request = string.fromBytes(await stream.readLp(1024)).split('|')
      if request.len != 3 or request[2] != c.signature:
        raise newException(ValueError, "invalid control request")
      let index = parseInt(request[1])
      if index < 0 or index >= c.expected:
        raise newException(ValueError, "participant index out of range")
      if c.peers.hasKey(index) and c.peers[index] != stream.peerId:
        raise
          newException(ValueError, "participant index already belongs to another peer")
      for existingIndex, peer in c.peers:
        if peer == stream.peerId and existingIndex != index:
          raise newException(ValueError, "peer already registered with another index")
      c.peers[index] = stream.peerId
      case request[0]
      of "register":
        discard
      of "ready":
        c.ready.incl(index)
      of "published":
        if c.ready.len != c.expected:
          raise newException(ValueError, "published before all participants were ready")
        c.published.incl(index)
      of "verified":
        if c.published.len != c.expected:
          raise newException(ValueError, "verified before all participants published")
        c.verified.incl(index)
      of "failed":
        c.failure = "participant " & $index & " reported failure"
        error "Participant reported failure", index = index, peerId = stream.peerId
      else:
        raise newException(ValueError, "unknown control request")
      await stream.writeLp(c.phase())
    except CancelledError as exc:
      raise exc
    except LPStreamError as exc:
      warn "Control stream failed", peerId = stream.peerId, error = exc.msg
    except CatchableError as exc:
      c.failure = "control protocol error: " & exc.msg
      error "Control protocol error", peerId = stream.peerId, error = exc.msg
      try:
        await stream.writeLp("failed")
      except CatchableError:
        discard
    finally:
      await stream.close()

  LPProtocol.new(@[ControlCodec], handle)

proc exchange*(
    switch: Switch, peer: PeerId, command: string, index: int, signature: string
): Future[string] {.async.} =
  let stream = await switch.dial(peer, ControlCodec)
  try:
    await stream.writeLp(command & "|" & $index & "|" & signature)
    return string.fromBytes(await stream.readLp(1024))
  finally:
    await stream.close()
