# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import chronos
import libp2p
import libp2p/transports/transport
import libp2p/muxers/muxer

type DialOnlyTransport = ref object of Transport
  inner: Transport

proc dialOnly*(inner: Transport): Transport {.raises: [].} =
  ## TCP/QUIC start methods require a listen address. Initialize only the common
  ## lifecycle for the secondary transport: outgoing QUIC sockets are created
  ## lazily, and TCP creates a socket for each dial.
  let wrapper = DialOnlyTransport(inner: inner)
  wrapper.initialize()
  wrapper

method start*(
    self: DialOnlyTransport, addresses: seq[MultiAddress]
) {.async: (raises: [LPError, transport.TransportError, CancelledError]).} =
  if addresses.len != 0:
    raise newException(TransportStartError, "Dial-only transport cannot listen")
  await procCall self.inner.start(@[])
  # Leave the wrapper's running flag false so Switch skips its accept loop.

method stop*(self: DialOnlyTransport) {.async: (raises: []).} =
  await self.inner.stop()

method handles*(self: DialOnlyTransport, address: MultiAddress): bool {.raises: [].} =
  self.inner.handles(address)

method dial*(
    self: DialOnlyTransport,
    hostname: string,
    address: MultiAddress,
    peerId: Opt[PeerId] = Opt.none(PeerId),
    dir: Direction = Direction.Out,
): Future[RawConn] {.async: (raises: [transport.TransportError, CancelledError]).} =
  return await self.inner.dial(hostname, address, peerId, dir)

method upgrade*(
    self: DialOnlyTransport, conn: RawConn, peerId: Opt[PeerId]
): Future[Muxer] {.async: (raises: [CancelledError, LPError], raw: true).} =
  self.inner.upgrade(conn, peerId)
