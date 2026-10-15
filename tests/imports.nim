# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import std/[algorithm, macros, os, sequtils, strutils]

proc printImportSummary(importedFiles: seq[string], baseDir: string) =
  echo "\n=================================="
  echo "Dynamic test import"
  echo "Imported ", importedFiles.len, " files."
  echo ""
  for file in importedFiles:
    echo file.replace(baseDir.parentDir() & DirSep, "")
  echo "==================================\n"

macro importTests*(
    dir: static string, ignorePaths: static seq[string], matchPath: static string = ""
): untyped =
  ## Recursively imports test_*.nim files, excluding test_all.nim.
  let imports = newStmtList()
  var matchingFiles: seq[string] = @[]
  let normalizedMatch = matchPath.replace('\\', '/')
  var pendingDirs = @[dir]

  while pendingDirs.len > 0:
    for kind, file in walkDir(pendingDirs.pop()):
      if kind == pcDir:
        if lastPathPart(file) notin ["nimbledeps", "nimcache"]:
          pendingDirs.add(file)
        continue
      if kind notin {pcFile, pcLinkToFile}:
        continue

      let (path, name, ext) = splitFile(file)
      if not name.startsWith("test_") or name == "test_all" or ext != ".nim":
        continue
      let isIgnored = ignorePaths.len > 0 and ignorePaths.anyIt(path.contains(it))
      let isMatched = normalizedMatch.len == 0 or file.replace('\\', '/').contains(normalizedMatch)
      if not isIgnored and isMatched:
        matchingFiles.add(file)

  sort(matchingFiles, proc(a, b: string): int = cmp(a.replace('\\', '/'), b.replace('\\', '/')))
  for file in matchingFiles:
    imports.add(newNimNode(nnkImportStmt).add(newLit(file)))

  printImportSummary(matchingFiles, dir)
  imports
