# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH
{.used.}

import std/[os, unittest], results

import network_lab/common/gossipsub_node

const TestEnvironmentVariable = "NETWORK_LAB_TEST_POSITIVE_INT"
const TestPeerId = "12D3KooWLbteJ8m8KoVktnMLH3oYKJcJRmrNdcKpk88vfZ5x5wSq"

proc withEnvironmentValue(value: string, body: proc() {.closure.}) =
  let originalValue = getEnv(TestEnvironmentVariable)
  let wasDefined = existsEnv(TestEnvironmentVariable)
  defer:
    if wasDefined:
      putEnv(TestEnvironmentVariable, originalValue)
    else:
      delEnv(TestEnvironmentVariable)

  putEnv(TestEnvironmentVariable, value)
  body()

suite "positive integer environment parsing":
  test "empty value uses the default":
    withEnvironmentValue("") do():
      check parsePositiveIntEnv(TestEnvironmentVariable, 17) == 17

  test "malformed value uses the default":
    withEnvironmentValue("not-a-number") do():
      check parsePositiveIntEnv(TestEnvironmentVariable, 17) == 17

  test "zero uses the default":
    withEnvironmentValue("0") do():
      check parsePositiveIntEnv(TestEnvironmentVariable, 17) == 17

  test "negative value uses the default":
    withEnvironmentValue("-5") do():
      check parsePositiveIntEnv(TestEnvironmentVariable, 17) == 17

  test "overflowing value uses the default":
    withEnvironmentValue("999999999999999999999999999999999999") do():
      check parsePositiveIntEnv(TestEnvironmentVariable, 17) == 17

suite "bootstrap address parsing":
  test "requires a terminal peer ID":
    let parsed = parseBootstrapAddress("/ip4/127.0.0.1/tcp/9000")
    check parsed.isErr

  test "extracts the peer ID and transport address":
    let parsed = parseBootstrapAddress("/ip4/127.0.0.1/tcp/9000/p2p/" & TestPeerId)
    require parsed.isOk
    check $parsed.get().peerId == TestPeerId
    check $parsed.get().transportAddress == "/ip4/127.0.0.1/tcp/9000"
