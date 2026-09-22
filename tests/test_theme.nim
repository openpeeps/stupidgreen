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
  "themes/mytheme/theme.yaml",
  "themes/mytheme/layouts/base.timl",
  "themes/mytheme/partials/header.timl",
  "themes/mytheme/partials/post-cards.timl",
  "themes/mytheme/partials/pagination.timl",
  "themes/mytheme/views/index.timl",
  "themes/mytheme/views/page.timl",
  "themes/mytheme/views/post.timl",
  "themes/mytheme/views/tag.timl",
  "themes/mytheme/views/category.timl",
  "themes/mytheme/views/search.timl",
  "themes/mytheme/views/errors/4xx.timl",
  "themes/mytheme/views/errors/5xx.timl",
  "themes/mytheme/assets/style.css",
]

proc runTests() =
  binPath = getCurrentDir() / "build" / "stupidgreen"
  if not fileExists(binPath):
    fail("StupidGreen binary not found. Run `clue build` first: " & binPath)

  let dir = createTempDir("stupidgreen_theme_", "")
  defer: removeDir(dir)

  # scaffold a new project
  let newRes = execCmdEx(quoteShell(binPath) & " new " & quoteShell(dir))
  if newRes.exitCode != 0:
    fail("`stupidgreen new` failed: " & newRes.output)

  # scaffold a blank theme (runs with the project as cwd)
  let themeRes = execCmdEx("cd " & quoteShell(dir) & " && " &
    quoteShell(binPath) & " theme mytheme")
  if themeRes.exitCode != 0:
    fail("`stupidgreen theme mytheme` failed: " & themeRes.output)
  for rel in themeFiles:
    assertFile(dir, rel)
  assertContains(dir, "themes/mytheme/theme.yaml", "name: \"mytheme\"")
  assertContains(dir, "themes/mytheme/theme.yaml", "author:")
  assertContains(dir, "themes/mytheme/theme.yaml", "version:")
  # no external CSS, no fonts in the skeleton
  assertContains(dir, "themes/mytheme/assets/style.css", ".post-content")
  assertContains(dir, "themes/mytheme/assets/style.css", ".branch::before")
  let styleCss = readFile(dir / "themes/mytheme/assets/style.css")
  if "bootstrap" in styleCss.toLowerAscii or "@font-face" in styleCss:
    fail("skeleton style.css must not reference external CSS or fonts")
  # timl skeleton keeps the functional hooks
  assertContains(dir, "themes/mytheme/views/post.timl", "share-markdown-content")
  assertContains(dir, "themes/mytheme/views/post.timl", "data-share-markdown")
  assertContains(dir, "themes/mytheme/views/post.timl", "branch-")
  assertContains(dir, "themes/mytheme/partials/header.timl", "spotlight-form")
  assertContains(dir, "themes/mytheme/views/search.timl", "search-results")

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

  # outside a project it fails
  let outsideDir = createTempDir("stupidgreen_theme_outside_", "")
  defer: removeDir(outsideDir)
  let outsideRes = execCmdEx("cd " & quoteShell(outsideDir) & " && " &
    quoteShell(binPath) & " theme mytheme")
  if outsideRes.exitCode == 0:
    fail("`stupidgreen theme` outside a project should fail")
  if "No StupidGreen project" notin outsideRes.output:
    fail("outside-project error should mention the missing project")

  # activate the new theme and build the whole site with it
  let themeConfig = dir / "stupidgreen.config.yaml"
  writeFile(themeConfig,
    readFile(themeConfig).replace("theme: \"default\"", "theme: \"mytheme\""))
  let buildRes = execCmdEx(quoteShell(binPath) & " build " & quoteShell(dir))
  if buildRes.exitCode != 0:
    fail("`stupidgreen build` (blank theme) failed: " & buildRes.output)
  let outDir = dir / "_build"
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
