# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import std/os
import ./imports

const path {.strdefine.} = ""

when path == "":
  importTests(currentSourcePath().parentDir(), @[])
else:
  importTests(currentSourcePath().parentDir(), @[], path)
