# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import std/[sets, unittest]
import results
import network_lab/common/regression_messages

suite "GossipSub delivery accounting":
  test "99 percent rounds upward and uses all remote publishers":
    check requiredDeliveries(499, 3, 99) == 1480
    check requiredDeliveries(2, 3, 99) == 3

  test "only unique valid remote messages contribute to delivery":
    let state = Received(runId: "run")
    check state.record(message("run", 1, 0), 0, 2, 3).isOk
    check state.record(message("run", 1, 0), 0, 2, 3).isOk
    check state.record(message("run", 0, 0), 0, 2, 3).isOk
    check state.seen.len == 1
    check state.selfCount == 1
    check state.record(message("other", 1, 1), 0, 2, 3).isErr
    check state.record(message("run", 2, 1), 0, 2, 3).isErr
    check state.record("run|1|9|network-lab-regression", 0, 2, 3).isErr
    check state.seen.len == 1

  test "delivery threshold fails at 1479 and passes at 1480":
    let state = Received(runId: "run")
    for publisher in 1 ..< 499:
      for round in 0 ..< 3:
        if state.seen.len < 1479:
          check state.record(message("run", publisher, round), 0, 499, 3).isOk
    let required = requiredDeliveries(499, 3, 99)
    check state.seen.len < required
    check state.record(message("run", 494, 0), 0, 499, 3).isOk
    check state.seen.len >= required
