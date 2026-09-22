# StupidGreen integration test
#
# Scaffolds a blank theme with `stupidgreen theme <name>` and verifies
# the generated skeleton, its validation errors, and that a project
# using the new theme builds successfully.
#
# (c) 2026 George Lemon | AGPL-3.0-or-later License

import std/[os, osproc, strutils, tempfiles]

var
  binPath {.used.}: string

proc fail(msg: string) =
  stderr.writeLine("FAILED: " & msg)
  quit(1)

proc assertFile(project, rel: string) =
  if not fileExists(project / rel):
    fail("expected file does not exist: " & rel)

proc assertContains(project, rel, needle: string) =
  if not fileExists(project / rel):
    fail("expected file does not exist: " & rel)
  let content = readFile(project / rel)
  if needle notin content:
    fail("expected `" & needle & "` in " & rel)

const themeFiles = [
  "mytheme/theme.yaml",
  "mytheme/layouts/base.timl",
  "mytheme/partials/header.timl",
  "mytheme/partials/post-cards.timl",
  "mytheme/partials/pagination.timl",
  "mytheme/views/index.timl",
  "mytheme/views/page.timl",
  "mytheme/views/post.timl",
  "mytheme/views/tag.timl",
  "mytheme/views/category.timl",
  "mytheme/views/search.timl",
  "mytheme/views/errors/4xx.timl",
  "mytheme/views/errors/5xx.timl",
  "mytheme/assets/style.css",
]

proc runTests() =
  binPath = getCurrentDir() / "build" / "stupidgreen"
  if not fileExists(binPath):
    fail("StupidGreen binary not found. Run `clue build` first: " & binPath)

  # scaffold a blank theme in an empty dir — no project required
  let dir = createTempDir("stupidgreen_theme_", "")
  defer: removeDir(dir)

  let themeRes = execCmdEx("cd " & quoteShell(dir) & " && " &
    quoteShell(binPath) & " theme mytheme")
  if themeRes.exitCode != 0:
    fail("`stupidgreen theme mytheme` failed: " & themeRes.output)
  for rel in themeFiles:
    assertFile(dir, rel)
  assertContains(dir, "mytheme/theme.yaml", "name: \"mytheme\"")
  assertContains(dir, "mytheme/theme.yaml", "author:")
  assertContains(dir, "mytheme/theme.yaml", "version:")
  # no external CSS, no fonts in the skeleton
  assertContains(dir, "mytheme/assets/style.css", ".post-content")
  assertContains(dir, "mytheme/assets/style.css", ".branch::before")
  let styleCss = readFile(dir / "mytheme/assets/style.css")
  if "bootstrap" in styleCss.toLowerAscii or "@font-face" in styleCss:
    fail("skeleton style.css must not reference external CSS or fonts")
  # timl skeleton keeps the functional hooks
  assertContains(dir, "mytheme/views/post.timl", "share-markdown-content")
  assertContains(dir, "mytheme/views/post.timl", "data-share-markdown")
  assertContains(dir, "mytheme/views/post.timl", "branch-")
  assertContains(dir, "mytheme/partials/header.timl", "spotlight-form")
  assertContains(dir, "mytheme/views/search.timl", "search-results")

  # duplicate theme name fails
  let dupRes = execCmdEx("cd " & quoteShell(dir) & " && " &
    quoteShell(binPath) & " theme mytheme")
  if dupRes.exitCode == 0:
    fail("duplicate `stupidgreen theme mytheme` should fail")
  if "already exists" notin dupRes.output:
    fail("duplicate theme error should say it already exists")

  # invalid names fail
  for bad in ["Bad Name", "has.dot", "UPPER", ""]:
    let badRes = execCmdEx("cd " & quoteShell(dir) & " && " &
      quoteShell(binPath) & " theme " & quoteShell(bad))
    if badRes.exitCode == 0:
      fail("`stupidgreen theme " & bad & "` should fail")

  # the built-in fallback name is reserved
  let reservedRes = execCmdEx("cd " & quoteShell(dir) & " && " &
    quoteShell(binPath) & " theme default")
  if reservedRes.exitCode == 0:
    fail("`stupidgreen theme default` should fail")

  # outside a project it still works (themes need no project)
  let outsideDir = createTempDir("stupidgreen_theme_outside_", "")
  defer: removeDir(outsideDir)
  let outsideRes = execCmdEx("cd " & quoteShell(outsideDir) & " && " &
    quoteShell(binPath) & " theme mytheme")
  if outsideRes.exitCode != 0:
    fail("`stupidgreen theme` outside a project should succeed: " & outsideRes.output)
  assertFile(outsideDir, "mytheme/theme.yaml")

  # copy the new theme into a project, activate it and build with it
  let projDir = createTempDir("stupidgreen_theme_proj_", "")
  defer: removeDir(projDir)
  let newRes = execCmdEx(quoteShell(binPath) & " new " & quoteShell(projDir))
  if newRes.exitCode != 0:
    fail("`stupidgreen new` failed: " & newRes.output)
  copyDir(dir / "mytheme", projDir / "themes" / "mytheme")

  # activate the new theme and build the whole site with it
  let themeConfig = projDir / "stupidgreen.config.yaml"
  writeFile(themeConfig,
    readFile(themeConfig).replace("theme: \"default\"", "theme: \"mytheme\""))
  let buildRes = execCmdEx(quoteShell(binPath) & " build " & quoteShell(projDir))
  if buildRes.exitCode != 0:
    fail("`stupidgreen build` (blank theme) failed: " & buildRes.output)
  let outDir = projDir / "_build"
  assertFile(outDir, "index.html")
  assertFile(outDir, "posts/hello-world/index.html")
  assertFile(outDir, "about/index.html")
  assertFile(outDir, "assets/style.css")
  assertContains(outDir, "index.html", "Hello World")
  assertContains(outDir, "posts/hello-world/index.html", "Welcome to your brand new")
  assertContains(outDir, "assets/style.css", ".post-content")

  echo "OK: all stupidgreen theme tests passed"
  quit(0)

when isMainModule:
  runTests()
