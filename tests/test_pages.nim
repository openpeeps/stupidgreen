# StupidGreen integration test
#
# Scaffolds a pages-only project with `stupidgreen new --pages` and verifies
# the generated static site: homepage from `pages/index.md`, custom routes
# from nested pages, per-page `layout` views, and no blogging leftovers
# (no posts/tags/categories/feed).
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

proc assertMissing(project, rel: string) =
  if fileExists(project / rel) or dirExists(project / rel):
    fail("did not expect file or directory: " & rel)

proc runTests() =
  binPath = getCurrentDir() / "build" / "stupidgreen"
  if not fileExists(binPath):
    fail("StupidGreen binary not found. Run `clue build` first: " & binPath)

  # --- scaffold a pages-only project ---
  let dir = createTempDir("stupidgreen_pages_", "")
  defer: removeDir(dir)

  let newRes = execCmdEx(quoteShell(binPath) & " new --pages " & quoteShell(dir))
  if newRes.exitCode != 0:
    fail("`stupidgreen new --pages` failed: " & newRes.output)
  assertFile(dir, "stupidgreen.config.yaml")
  assertFile(dir, "pages/index.md")
  assertFile(dir, "pages/about.md")
  assertFile(dir, "pages/llms.md")
  assertContains(dir, "stupidgreen.config.yaml", "mode: \"pages\"")
  if dirExists(dir / "posts"):
    fail("a pages-only project must not scaffold `posts/`")

  # --- custom routes: nested pages + a page with a custom layout ---
  createDir(dir / "pages" / "projects")
  writeFile(dir / "pages" / "projects" / "demo.md",
    "---\ntitle: \"Demo Project\"\ndraft: false\n---\n\n# Demo Project\n\nA project page.\n")
  writeFile(dir / "pages" / "landing.md",
    "---\ntitle: \"Landing\"\nlayout: \"landing\"\ndraft: false\n---\n\n# Landing\n\nLanding body.\n")

  # minimal custom theme providing only the `landing` view;
  # everything else falls back to the default theme
  createDir(dir / "themes" / "custom" / "views")
  writeFile(dir / "themes" / "custom" / "theme.yaml",
    "name: \"custom\"\nversion: \"0.1.0\"\n")
  writeFile(dir / "themes" / "custom" / "views" / "landing.timl",
    "@include \"header\"\ndiv\n  p: \"LANDING LAYOUT MARKER\"\n" &
    "  h1: $this[\"page\"][\"meta\"][\"title\"]\n" &
    "  article.post-content: $this[\"page\"][\"content\"]\n")
  let themeConfig = dir / "stupidgreen.config.yaml"
  writeFile(themeConfig,
    readFile(themeConfig).replace("theme: \"default\"", "theme: \"custom\""))

  let buildRes = execCmdEx(quoteShell(binPath) & " build " & quoteShell(dir))
  if buildRes.exitCode != 0:
    fail("`stupidgreen build` (pages mode) failed: " & buildRes.output)

  let outDir = dir / "_build"
  # homepage renders `pages/index.md` through the page view
  assertFile(outDir, "index.html")
  assertContains(outDir, "index.html", "Welcome to StupidGreen")
  assertFile(outDir, "about/index.html")
  assertContains(outDir, "about/index.html", "About")
  assertFile(outDir, "projects/demo/index.html")
  assertContains(outDir, "projects/demo/index.html", "Demo Project")
  # the custom layout view renders for `layout: landing`
  assertFile(outDir, "landing/index.html")
  assertContains(outDir, "landing/index.html", "LANDING LAYOUT MARKER")
  assertContains(outDir, "landing/index.html", "Landing body")
  assertFile(outDir, "sitemap.xml")
  assertFile(outDir, "results.json")
  assertContains(outDir, "sitemap.xml", "/about")
  assertContains(outDir, "sitemap.xml", "/projects/demo")
  assertContains(outDir, "sitemap.xml", "/landing")
  assertContains(outDir, "results.json", "/landing")

  # no blogging leftovers in a pages-only build
  assertMissing(outDir, "posts")
  assertMissing(outDir, "tags")
  assertMissing(outDir, "categories")
  assertMissing(outDir, "page")
  assertMissing(outDir, "feed.xml")
  let sitemap = readFile(outDir / "sitemap.xml")
  if "/tags/" in sitemap or "/posts/" in sitemap or "/categories/" in sitemap:
    fail("pages sitemap must not reference blog routes")

  # --- unknown layouts fall back to the page view with a warning ---
  writeFile(dir / "pages" / "mystery.md",
    "---\ntitle: \"Mystery\"\nlayout: \"nope\"\ndraft: false\n---\n\n# Mystery\n\nMystery body.\n")
  let buildResFallback = execCmdEx(quoteShell(binPath) & " build " & quoteShell(dir))
  if buildResFallback.exitCode != 0:
    fail("`stupidgreen build` (unknown layout) failed: " & buildResFallback.output)
  if "Unknown layout" notin buildResFallback.output:
    fail("unknown layout should warn and fall back")
  assertFile(outDir, "mystery/index.html")
  assertContains(outDir, "mystery/index.html", "Mystery body")

  # --- `stupidgreen post` is refused in pages mode ---
  let postRes = execCmdEx("cd " & quoteShell(dir) & " && " &
    quoteShell(binPath) & " post " & quoteShell("Hello"))
  if postRes.exitCode == 0:
    fail("`stupidgreen post` should fail in pages mode")
  if "pages mode" notin postRes.output:
    fail("refused `post` should mention pages mode")

  # --- pages mode without `pages/index.md` fails with a clear error ---
  let emptyDir = createTempDir("stupidgreen_pages_empty_", "")
  defer: removeDir(emptyDir)
  let newRes2 = execCmdEx(quoteShell(binPath) & " new --pages " & quoteShell(emptyDir))
  if newRes2.exitCode != 0:
    fail("`stupidgreen new --pages` failed: " & newRes2.output)
  removeFile(emptyDir / "pages" / "index.md")
  let buildResEmpty = execCmdEx(quoteShell(binPath) & " build " & quoteShell(emptyDir))
  if buildResEmpty.exitCode == 0:
    fail("pages build without `pages/index.md` should fail")
  if "pages/index.md" notin buildResEmpty.output:
    fail("missing homepage error should mention `pages/index.md`")

  echo "OK: all stupidgreen pages tests passed"
  quit(0)

when isMainModule:
  runTests()
