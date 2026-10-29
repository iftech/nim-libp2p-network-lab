# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import std/random

import chronicles
import network_lab/common/env_values

randomize()

let percentageResult = getEnvInt("FAILURE_PERCENT", 10, 0, 100)
let percentage =
  if percentageResult.isOk:
    percentageResult.get()
  else:
    warn "Invalid FAILURE_PERCENT; using default", error = percentageResult.error
    10
if rand(99) < percentage:
  let code = rand(1 .. 255)
  error "Exiting with error code", code = code
  quit(code)

debug "Success"
quit(0)
