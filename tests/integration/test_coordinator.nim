# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import std/[os, unittest]
import chronos, libp2p, results
import network_lab/common/[coordinator, env_values, gossipsub_node]
import network_lab/nodes/bootstrap/main as bootstrap

proc completionNotification() {.async.} =
  let started = newFuture[MultiAddress]("bootstrap started")
  let boot = bootstrap.main(started)
  let address = await started.wait(10.seconds)
  let listen = MultiAddress.init("/ip4/127.0.0.1/tcp/0").get()
  var clients: seq[Switch]
  try:
    var peer: PeerId
    for i in 0 ..< 3:
      let client = buildSwitch(listen).get()
      clients.add(client)
      await client.start()
      peer = await client.connect(address, allowUnknownPeerId = true)
    let signature = loadEnvConfig(true).get().configSignature()
    for command in ["register", "ready", "published"]:
      for i, client in clients:
        doAssert (await exchange(client, peer, command, i, signature)).isOk
    for i, client in clients:
      let response = (await exchange(client, peer, "verified", i, signature)).get()
      doAssert response == (if i == 2: "complete" else: "verify")

    # The first two participants have verified, but have not yet heard that
    # everyone is done. The bootstrap must remain available for their retries.
    await sleepAsync(2.seconds)
    doAssert not boot.finished()
    for i in 0 ..< 2:
      doAssert (await exchange(clients[i], peer, "verified", i, signature)).get() ==
        "complete"
    doAssert (await boot.wait(5.seconds)) == 0
  finally:
    for client in clients:
      await client.stop()
    if not boot.finished():
      await boot.cancelAndWait()

proc failurePropagation() {.async.} =
  let started = newFuture[MultiAddress]("bootstrap started")
  let boot = bootstrap.main(started)
  let address = await started.wait(10.seconds)
  let listen = MultiAddress.init("/ip4/127.0.0.1/tcp/0").get()
  var clients: seq[Switch]
  var peer: PeerId
  try:
    for i in 0 ..< 3:
      let client = buildSwitch(listen).get()
      clients.add(client)
      await client.start()
      peer = await client.connect(address, allowUnknownPeerId = true)
    let signature = loadEnvConfig(true).get().configSignature()
    for i, client in clients:
      doAssert (await exchange(client, peer, "register", i, signature)).get() == "ready"
    let first = await exchange(
      clients[0], peer, "failed", 0, signature, "delivery below threshold | details"
    )
    doAssert first.get() ==
      "failed|participant 0 reported failure: delivery below threshold | details"
    await sleepAsync(2.seconds)
    doAssert not boot.finished()
    let second =
      await exchange(clients[1], peer, "failed", 1, signature, "secondary failure")
    doAssert second.get() == first.get()
    let third = await exchange(clients[2], peer, "ready", 2, signature)
    doAssert third.get() == first.get()
    doAssert (await boot.wait(5.seconds)) == 1
  finally:
    for client in clients:
      await client.stop()
    if not boot.finished():
      await boot.cancelAndWait()

suite "coordinator lifecycle":
  test "first failure is delivered while bootstrap remains available":
    let keys = ["TRANSPORT", "PARTICIPANTS", "LISTEN_ADDR", "SELF_CHECK_TIMEOUT_SECS"]
    var old: seq[(bool, string)]
    for key in keys:
      old.add((existsEnv(key), getEnv(key)))
    defer:
      for i, key in keys:
        if old[i][0]:
          putEnv(key, old[i][1])
        else:
          delEnv(key)
    putEnv("TRANSPORT", "TCP")
    putEnv("PARTICIPANTS", "3")
    putEnv("LISTEN_ADDR", "/ip4/127.0.0.1/tcp/0")
    putEnv("SELF_CHECK_TIMEOUT_SECS", "60")
    waitFor failurePropagation().wait(20.seconds)

  test "bootstrap exits after notifying all participants of completion":
    let keys = ["TRANSPORT", "PARTICIPANTS", "LISTEN_ADDR", "SELF_CHECK_TIMEOUT_SECS"]
    var old: seq[(bool, string)]
    for key in keys:
      old.add((existsEnv(key), getEnv(key)))
    defer:
      for i, key in keys:
        if old[i][0]:
          putEnv(key, old[i][1])
        else:
          delEnv(key)
    putEnv("TRANSPORT", "TCP")
    putEnv("PARTICIPANTS", "3")
    putEnv("LISTEN_ADDR", "/ip4/127.0.0.1/tcp/0")
    putEnv("SELF_CHECK_TIMEOUT_SECS", "60")
    waitFor completionNotification().wait(20.seconds)
