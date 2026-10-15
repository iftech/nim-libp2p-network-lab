# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH
{.used.}

import std/os

import chronos
import libp2p

import ../tools/unittest
import network_lab/nodes/bootstrap/main as bootstrap_main
import network_lab/nodes/gossipsub/main as gossipsub_main

const TestTopic = "network-lab-integration-test"

proc runNodeIntegrationTest(): Future[bool] {.async.} =
  let environmentNames =
    ["LISTEN_ADDR", "BOOTSTRAP_ADDR", "GOSSIPSUB_TOPIC", "SELF_CHECK_TIMEOUT_SECS"]
  var originalEnvironment: array[4, tuple[defined: bool, value: string]]
  for index, name in environmentNames:
    originalEnvironment[index] = (existsEnv(name), getEnv(name))

  let
    started = newFuture[MultiAddress]("Bootstrap node started")
    shutdownRequested = newAsyncEvent()

  putEnv("LISTEN_ADDR", "/ip4/127.0.0.1/tcp/0")
  putEnv("GOSSIPSUB_TOPIC", TestTopic)
  putEnv("SELF_CHECK_TIMEOUT_SECS", "10")
  delEnv("BOOTSTRAP_ADDR")

  let bootstrapFuture = bootstrap_main.main(started, shutdownRequested)
  try:
    let bootstrapAddress = await started.wait(10.seconds)
    putEnv("BOOTSTRAP_ADDR", $bootstrapAddress)
    putEnv("LISTEN_ADDR", "/ip4/127.0.0.1/tcp/0")

    let gossipExitCode = await gossipsub_main.main()
    shutdownRequested.fire()
    let bootstrapExitCode = await bootstrapFuture
    return bootstrapExitCode == 0 and gossipExitCode == 0
  except AsyncTimeoutError:
    return false
  finally:
    shutdownRequested.fire()
    if not bootstrapFuture.finished():
      discard await bootstrapFuture

    for index, name in environmentNames:
      if originalEnvironment[index].defined:
        putEnv(name, originalEnvironment[index].value)
      else:
        delEnv(name)

suite "Integration :: GossipSub":
  asyncTest "Bootstrap and GossipSub mains complete the self-check":
    check await runNodeIntegrationTest()
