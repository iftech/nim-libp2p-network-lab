# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import chronos, unittest2

export unittest2 except suite

const
  asyncTestTimeoutDefault* = 15.seconds
  asyncTestCleanupTimeout = 1.seconds

var
  suiteAsyncTestTimeout {.threadvar.}: Duration
  hasSuiteAsyncTestTimeout {.threadvar.}: bool

template withSuiteAsyncTestTimeout(timeout: untyped, body: untyped): untyped =
  let previousTimeout = suiteAsyncTestTimeout
  let hadPreviousTimeout = hasSuiteAsyncTestTimeout
  suiteAsyncTestTimeout = timeout
  hasSuiteAsyncTestTimeout = true
  defer:
    suiteAsyncTestTimeout = previousTimeout
    hasSuiteAsyncTestTimeout = hadPreviousTimeout
  body

template suite*(name: string, timeout: untyped, body: untyped): untyped =
  block:
    proc testSuite() =
      withSuiteAsyncTestTimeout(timeout):
        unittest2.suite name:
          body

    testSuite()

template suite*(name: string, body: untyped): untyped =
  block:
    proc testSuite() =
      withSuiteAsyncTestTimeout(asyncTestTimeoutDefault):
        unittest2.suite name:
          body

    testSuite()

template asyncTest*(name: string, body: untyped): untyped =
  asyncTest(
    name,
    if hasSuiteAsyncTestTimeout: suiteAsyncTestTimeout else: asyncTestTimeoutDefault,
    body,
  )

template asyncTest*(name: string, timeout: untyped, body: untyped): untyped =
  test name:
    let testFut = (
      proc() {.async.} =
        body
    )()
    try:
      waitFor testFut.wait(timeout)
    except AsyncTimeoutError as exc:
      checkpoint "[TEST TIMEOUT] Test body exceeded its configured timeout of " &
        $timeout & "."
      try:
        waitFor testFut.cancelAndWait().wait(asyncTestCleanupTimeout)
      except AsyncTimeoutError:
        checkpoint "[TIMEOUT] Timed out waiting for the test body to cancel."
      raise exc
