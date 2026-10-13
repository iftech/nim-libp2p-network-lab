# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import chronos

proc waitShutdownSignal*() {.async: (raises: [CancelledError]).} =
  ## Wait until the process receives SIGINT or SIGTERM.
  let
    sigIntFut = waitSignal(SIGINT)
    sigTermFut = waitSignal(SIGTERM)

  try:
    let completedSignalFut = await one(sigIntFut, sigTermFut)
    await completedSignalFut
  except AsyncError as e:
    raiseAssert "unexpected AsyncError in waitShutdownSignal: " & e.msg
  finally:
    await noCancel(sigIntFut.cancelAndWait())
    await noCancel(sigTermFut.cancelAndWait())
