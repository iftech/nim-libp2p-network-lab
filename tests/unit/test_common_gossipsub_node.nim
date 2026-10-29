# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH
{.used.}

import std/[os, unittest], results

import libp2p

import network_lab/common/[env_values, gossipsub_node]

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
  test "empty value returns an error":
    withEnvironmentValue(TestEnvironmentVariable, "") do():
      check getEnvPositiveInt(TestEnvironmentVariable, 17).isErr

  test "malformed value returns an error":
    withEnvironmentValue(TestEnvironmentVariable, "not-a-number") do():
      check getEnvPositiveInt(TestEnvironmentVariable, 17).isErr

  test "zero returns an error":
    withEnvironmentValue(TestEnvironmentVariable, "0") do():
      check getEnvPositiveInt(TestEnvironmentVariable, 17).isErr

  test "negative value returns an error":
    withEnvironmentValue(TestEnvironmentVariable, "-5") do():
      check getEnvPositiveInt(TestEnvironmentVariable, 17).isErr

  test "overflowing value returns an error":
    withEnvironmentValue(
      TestEnvironmentVariable, "999999999999999999999999999999999999"
    ) do():
      check getEnvPositiveInt(TestEnvironmentVariable, 17).isErr

suite "configuration parsing":
  test "invalid listen address returns an error":
    withEnvironmentValue("LISTEN_ADDR", "not-a-multiaddress") do():
      check getEnvListenAddress().isErr

  test "missing bootstrap address returns an error":
    withEnvironmentValue("BOOTSTRAP_ADDR", "") do():
      check getEnvBootstrapAddress().isErr

  test "invalid announced address returns an error":
    let addressResult = MultiAddress.init("/ip4/127.0.0.1/tcp/0")
    require addressResult.isOk
    withEnvironmentValue("ANNOUNCE_ADDR", "not-a-multiaddress") do():
      check buildSwitch(addressResult.get()).isErr

  test "invalid private key returns an error":
    let addressResult = MultiAddress.init("/ip4/127.0.0.1/tcp/0")
    require addressResult.isOk
    withEnvironmentValue("ANNOUNCE_ADDR", "") do():
      withEnvironmentValue("PRIVATE_KEY", "not-hexadecimal") do():
        check buildSwitch(addressResult.get()).isErr

suite "bootstrap address parsing":
  test "requires a terminal peer ID":
    let addressResult = parseBootstrapAddress("/ip4/127.0.0.1/tcp/9000")
    check addressResult.isErr

  test "extracts the peer ID and transport address":
    let addressResult =
      parseBootstrapAddress("/ip4/127.0.0.1/tcp/9000/p2p/" & TestPeerId)
    require addressResult.isOk
    check $addressResult.get().peerId == TestPeerId
    check $addressResult.get().transportAddress == "/ip4/127.0.0.1/tcp/9000"
