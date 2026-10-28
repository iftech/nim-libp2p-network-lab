# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import std/[sets, strutils]
import results

type Received* = ref object
  runId*: string
  seen*: HashSet[string]
  selfCount*: int
  publishingStarted*: bool
  failure*: string

proc message*(runId: string, index, round: int): string =
  runId & "|" & $index & "|" & $round & "|network-lab-regression"

proc record*(
    state: Received, raw: string, ownIndex, participants, rounds: int
): Result[void, string] =
  try:
    let parts = raw.split('|')
    if parts.len != 4 or parts[0] != state.runId or parts[3] != "network-lab-regression":
      return err("invalid payload or run ID")
    let index = parseInt(parts[1])
    let round = parseInt(parts[2])
    if index < 0 or index >= participants or round < 0 or round >= rounds or
        raw != message(state.runId, index, round):
      return err("invalid publisher, sequence or payload")
    if index == ownIndex:
      inc state.selfCount
    else:
      state.seen.incl($index & ":" & $round)
    ok()
  except ValueError:
    err("invalid publisher or sequence")

proc requiredDeliveries*(participants, rounds, threshold: int): int =
  ((participants - 1) * rounds * threshold + 99) div 100
