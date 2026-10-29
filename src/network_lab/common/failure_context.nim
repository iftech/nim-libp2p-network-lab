# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import std/[json, syncio]

proc recordFailure*(role, phase, category, message: string) =
  ## A machine-readable final diagnosis, alongside the ordinary human logs.
  ## Diagnostics must never replace the original failure if stderr is unavailable.
  try:
    stderr.writeLine(
      "NETWORK_LAB_FAILURE " &
        $(%*{"role": role, "phase": phase, "category": category, "message": message})
    )
    stderr.flushFile()
  except IOError:
    discard
