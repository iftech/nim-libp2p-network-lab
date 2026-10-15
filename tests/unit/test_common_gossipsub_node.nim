# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH
{.used.}

import std/[os, unittest], results

import libp2p

import network_lab/common/gossipsub_node

const TestEnvironmentVariable = "NETWORK_LAB_TEST_POSITIVE_INT"
const TestPeerId = "12D3KooWLbteJ8m8KoVktnMLH3oYKJcJRmrNdcKpk88vfZ5x5wSq"

proc withEnvironmentValue(name, value: string, body: proc() {.closure.}) =
  let originalValue = getEnv(name)
  let wasDefined = existsEnv(name)
  defer:
    if wasDefined:
      putEnv(name, originalValue)
    else:
      delEnv(name)

  putEnv(name, value)
  body()

suite "positive integer environment parsing":
  test "empty value uses the default":
    withEnvironmentValue(TestEnvironmentVariable, "") do():
      check parsePositiveIntEnv(TestEnvironmentVariable, 17) == 17

  test "malformed value uses the default":
    withEnvironmentValue(TestEnvironmentVariable, "not-a-number") do():
      check parsePositiveIntEnv(TestEnvironmentVariable, 17) == 17

  test "zero uses the default":
    withEnvironmentValue(TestEnvironmentVariable, "0") do():
      check parsePositiveIntEnv(TestEnvironmentVariable, 17) == 17

  test "negative value uses the default":
    withEnvironmentValue(TestEnvironmentVariable, "-5") do():
      check parsePositiveIntEnv(TestEnvironmentVariable, 17) == 17

  test "overflowing value uses the default":
    withEnvironmentValue(
      TestEnvironmentVariable, "999999999999999999999999999999999999"
    ) do():
      check parsePositiveIntEnv(TestEnvironmentVariable, 17) == 17

suite "configuration parsing":
  test "invalid listen address returns an error":
    withEnvironmentValue("LISTEN_ADDR", "not-a-multiaddress") do():
      check listenAddress().isErr

  test "missing bootstrap address returns an error":
    withEnvironmentValue("BOOTSTRAP_ADDR", "") do():
      check bootstrapAddress().isErr

  test "invalid announced address returns an error":
    let address = MultiAddress.init("/ip4/127.0.0.1/tcp/0")
    require address.isOk
    withEnvironmentValue("ANNOUNCE_ADDR", "not-a-multiaddress") do():
      check buildSwitch(address.get()).isErr

  test "invalid private key returns an error":
    let address = MultiAddress.init("/ip4/127.0.0.1/tcp/0")
    require address.isOk
    withEnvironmentValue("ANNOUNCE_ADDR", "") do():
      withEnvironmentValue("PRIVATE_KEY", "not-hexadecimal") do():
        check buildSwitch(address.get()).isErr

suite "bootstrap address parsing":
  test "requires a terminal peer ID":
    let parsed = parseBootstrapAddress("/ip4/127.0.0.1/tcp/9000")
    check parsed.isErr

  test "extracts the peer ID and transport address":
    let parsed = parseBootstrapAddress("/ip4/127.0.0.1/tcp/9000/p2p/" & TestPeerId)
    require parsed.isOk
    check $parsed.get().peerId == TestPeerId
    check $parsed.get().transportAddress == "/ip4/127.0.0.1/tcp/9000"
