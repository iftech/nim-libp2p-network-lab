import std/[os, random, strutils]

import chronicles

proc failurePercent(): int =
  let value = getEnv("FAILURE_PERCENT", "10")
  try:
    result = parseInt(value)
    if result < 0 or result > 100:
      raise newException(ValueError, "must be in the range 0..100")
  except ValueError:
    warn "Invalid FAILURE_PERCENT; using default", value = value
    result = 10

randomize()

let percentage = failurePercent()
if rand(99) < percentage:
  let code = rand(1 .. 255)
  error "Exiting with error code", code = code
  quit(code)

debug "Success"
quit(0)
