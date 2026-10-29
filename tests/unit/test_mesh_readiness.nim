# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import std/unittest
import chronos
import network_lab/common/mesh_readiness

suite "mesh readiness":
  test "requires a continuous interval and resets after a drop":
    var state: MeshReadiness
    let start = Moment.now()
    state.observe(4, 4, start, 10.seconds)
    state.observe(4, 4, start + 9.seconds, 10.seconds)
    check not state.ready
    state.observe(3, 4, start + 9.seconds, 10.seconds)
    state.observe(4, 4, start + 10.seconds, 10.seconds)
    state.observe(4, 4, start + 19.seconds, 10.seconds)
    check not state.ready
    state.observe(4, 4, start + 20.seconds, 10.seconds)
    check state.ready
    state.observe(3, 4, start + 21.seconds, 10.seconds)
    check not state.ready
