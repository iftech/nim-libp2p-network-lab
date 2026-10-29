# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import chronos

type MeshReadiness* = object
  stableSince*: Moment
  stable*, ready*: bool

proc observe*(
    state: var MeshReadiness, count, minimum: int, now: Moment, interval: Duration
) =
  if count < minimum:
    state.stable = false
    state.ready = false
  elif not state.stable:
    state.stable = true
    state.stableSince = now
  elif now - state.stableSince >= interval:
    state.ready = true
