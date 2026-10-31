# StupidGreen site URL test
#
# Verifies `metadata.url` handling: bare domains/subpaths are normalized
# to absolute `site.baseUrl` asset links, and a missing URL fails fast.
#
# (c) 2026 George Lemon | MIT License

import std/[os, osproc, strutils, tempfiles]

var
  binPath {.used.}: string

proc fail(msg: string) =
  stderr.writeLine("FAILED: " & msg)
  quit(1)

proc runTests() =
  binPath = getCurrentDir() / "build" / "stupidgreen"
  if not fileExists(binPath):
    fail("StupidGreen binary not found. Run `clue build` first: " & binPath)

  # bare domain + subpath with trailing slash normalizes cleanly
  let dir = createTempDir("stupidgreen_siteurl_", "")
  defer: removeDir(dir)
  if execCmdEx(quoteShell(binPath) & " new " & quoteShell(dir)).exitCode != 0:
    fail("`stupidgreen new` failed")
  let configPath = dir / "stupidgreen.config.yaml"
  writeFile(configPath,
    readFile(configPath).replace("url: \"https://example.com\"", "url: \"mysite.com/docs/\""))
  if execCmdEx(quoteShell(binPath) & " build " & quoteShell(dir)).exitCode != 0:
    fail("`stupidgreen build` with subpath URL failed")
  let index = readFile(dir / "_build" / "index.html")
  if "https://mysite.com/docs/assets/style.css" notin index:
    fail("expected absolute baseUrl asset link in index.html")
  if "mysite.com//" in index:
    fail("double slashes in generated URLs")
  if "/feed.xml" notin index or "https://mysite.com/docs/feed.xml" notin index:
    fail("expected absolute feed link in index.html")

  # missing URL fails fast with a helpful message
  let dir2 = createTempDir("stupidgreen_siteurl_empty_", "")
  defer: removeDir(dir2)
  if execCmdEx(quoteShell(binPath) & " new " & quoteShell(dir2)).exitCode != 0:
    fail("`stupidgreen new` failed")
  let configPath2 = dir2 / "stupidgreen.config.yaml"
  writeFile(configPath2,
    readFile(configPath2).replace("url: \"https://example.com\"", "url: \"\""))
  let res = execCmdEx(quoteShell(binPath) & " build " & quoteShell(dir2))
  if res.exitCode == 0:
    fail("build with empty `metadata.url` should fail")
  if "metadata.url" notin res.output:
    fail("missing-URL error should mention `metadata.url`")

  echo "OK: all stupidgreen siteurl tests passed"
  quit(0)

when isMainModule:
  runTests()
