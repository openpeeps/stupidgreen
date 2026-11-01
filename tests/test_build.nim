# StupidGreen integration test
#
# Builds a temporary blog project with the StupidGreen binary and verifies
# the generated static site contains the expected files and content.
#
# (c) 2026 George Lemon | MIT License

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

proc runTests() =
  binPath = getCurrentDir() / "build" / "stupidgreen"
  if not fileExists(binPath):
    fail("StupidGreen binary not found. Run `nimble build` first: " & binPath)

  let dir = createTempDir("stupidgreen_test_", "")
  defer: removeDir(dir)

  # scaffold a new project
  let newRes = execCmdEx(quoteShell(binPath) & " new " & quoteShell(dir))
  if newRes.exitCode != 0:
    fail("`stupidgreen new` failed: " & newRes.output)
  assertFile(dir, "stupidgreen.config.yaml")
  assertFile(dir, "posts/index.md")
  assertFile(dir, "posts/hello-world.md")
  assertFile(dir, "pages/about.md")
  assertFile(dir, "pages/llms.md")
  assertFile(dir, "themes/default/theme.yaml")
  assertFile(dir, "themes/default/views/index.timl")
  assertFile(dir, "themes/default/views/post.timl")
  assertFile(dir, "themes/default/layouts/base.timl")
  assertFile(dir, "themes/default/partials/header.timl")
  assertFile(dir, "themes/default/assets/bootstrap.min.css")
  assertFile(dir, "themes/default/assets/app.js")
  assertContains(dir, "stupidgreen.config.yaml", "theme:")
  assertContains(dir, "stupidgreen.config.yaml", "server:")
  assertContains(dir, "themes/default/theme.yaml", "name:")

  # add a page in a subdirectory
  createDir(dir / "pages" / "projects")
  writeFile(dir / "pages" / "projects" / "demo.md",
    "---\ntitle: \"Demo Project\"\ndraft: false\n---\n\n# Demo Project\n\nA project page.\n")
  writeFile(dir / "pages" / "projects" / "index.md",
    "---\ntitle: \"Projects\"\ndraft: false\n---\n\n# Projects\n\nLanding page.\n")

  # a post that references another post via `@<file>.md`
  writeFile(dir / "posts" / "ref-test.md",
    "---\ntitle: \"Ref Test\"\ndraft: false\n---\n\nCheck this out: @hello-world.md\n\nUnknown: @somebrand.md\n")

  # generate the static site
  let buildRes = execCmdEx(quoteShell(binPath) & " build " & quoteShell(dir))
  if buildRes.exitCode != 0:
    fail("`stupidgreen build` failed: " & buildRes.output)

  let outDir = dir / "_build"
  assertFile(outDir, "index.html")
  assertFile(outDir, "posts/hello-world/index.html")
  assertFile(outDir, "posts/ref-test/index.html")
  assertFile(outDir, "about/index.html")
  assertFile(outDir, "projects/index.html")
  assertFile(outDir, "projects/demo/index.html")
  assertFile(outDir, "feed.xml")
  assertFile(outDir, "sitemap.xml")
  assertFile(outDir, "results.json")
  assertFile(outDir, "llms.txt")
  assertContains(outDir, "index.html", "Hello World")
  assertContains(outDir, "index.html", "Continue reading this story")
  assertContains(outDir, "posts/hello-world/index.html", "Welcome to your brand new")
  assertContains(outDir, "about/index.html", "About")
  assertContains(outDir, "projects/index.html", "Landing page")
  assertContains(outDir, "projects/demo/index.html", "Demo Project")
  assertContains(outDir, "llms.txt", "StupidGreen Blog")
  assertContains(outDir, "feed.xml", "<rss")

  # `@hello-world.md` renders as a post-reference card
  let refHtml = readFile(outDir / "posts" / "ref-test/index.html")
  if "post-ref" notin refHtml:
    fail("expected a post-reference card for `@hello-world.md`")
  if "Hello World" notin refHtml:
    fail("expected the referenced post's title in the card")
  if "/posts/hello-world" notin refHtml:
    fail("expected the referenced post's link in the card")
  if "@hello-world.md" in refHtml:
    fail("`@hello-world.md` should be replaced by its card")
  # unknown references must stay as plain text
  if "@somebrand.md" notin refHtml:
    fail("unknown `@somebrand.md` reference should be left as text")
  assertContains(outDir, "sitemap.xml", "<urlset")
  assertContains(outDir, "sitemap.xml", "/about")
  assertContains(outDir, "sitemap.xml", "/projects/demo")

  # pages must not leak into the RSS feed
  let feed = readFile(outDir / "feed.xml")
  if "Demo Project" in feed or "/about" in feed:
    fail("pages must not appear in the RSS feed")

  # --- themes (custom theme with fallback to default) ---
  createDir(dir / "themes" / "custom" / "views")
  createDir(dir / "themes" / "custom" / "assets")
  writeFile(dir / "themes" / "custom" / "theme.yaml",
    "name: \"custom\"\nversion: \"0.1.0\"\n")
  writeFile(dir / "themes" / "custom" / "views" / "index.timl",
    readFile(dir / "themes" / "default" / "views" / "index.timl") &
    "\n<!-- CUSTOM THEME MARKER -->\n")
  writeFile(dir / "themes" / "custom" / "assets" / "custom.css",
    "/* custom theme stylesheet */\n")
  # project assets always win over theme assets
  writeFile(dir / "assets" / "custom.css",
    "/* project override */\n")
  let themeConfig = dir / "stupidgreen.config.yaml"
  writeFile(themeConfig,
    readFile(themeConfig).replace("theme: \"default\"", "theme: \"custom\""))
  let buildResCustom = execCmdEx(quoteShell(binPath) & " build " & quoteShell(dir))
  if buildResCustom.exitCode != 0:
    fail("`stupidgreen build` (custom theme) failed: " & buildResCustom.output)
  # custom theme's index view is used ...
  assertContains(outDir, "index.html", "CUSTOM THEME MARKER")
  # ... while views missing from the custom theme fall back to default
  assertContains(outDir, "posts/hello-world/index.html", "Welcome to your brand new")
  # theme assets land in the public dir (custom + fallback default files) ...
  assertFile(outDir, "assets/custom.css")
  assertFile(outDir, "assets/bootstrap.min.css")
  # ... and project files win over theme files with the same name
  assertContains(outDir, "assets/custom.css", "project override")

  # --- themes (unknown theme fails with a clear error) ---
  writeFile(themeConfig,
    readFile(themeConfig).replace("theme: \"custom\"", "theme: \"nope\""))
  let buildResUnknown = execCmdEx(quoteShell(binPath) & " build " & quoteShell(dir))
  if buildResUnknown.exitCode == 0:
    fail("`stupidgreen build` (unknown theme) should fail")
  if "nope" notin buildResUnknown.output:
    fail("unknown theme error should name the theme")
  writeFile(themeConfig,
    readFile(themeConfig).replace("theme: \"nope\"", "theme: \"default\""))

  # --- title-derived slugs (`slugFromTitle`) ---
  let slugDir = createTempDir("stupidgreen_slug_", "")
  defer: removeDir(slugDir)

  let newRes2 = execCmdEx(quoteShell(binPath) & " new " & quoteShell(slugDir))
  if newRes2.exitCode != 0:
    fail("`stupidgreen new` failed: " & newRes2.output)

  # enable title-derived slugs
  let slugConfig = slugDir / "stupidgreen.config.yaml"
  writeFile(slugConfig,
    readFile(slugConfig).replace("slugFromTitle: false", "slugFromTitle: true"))

  # a post whose slug comes from its title, not the file name
  writeFile(slugDir / "posts" / "random-file-name.md",
    "---\ntitle: \"My Awesome Post\"\ndate: \"2026-08-06\"\ndraft: false\n---\n\n# My Awesome Post\n\nTitle-derived slug.\n")
  # a post that opts out with `slugify: false` -> keeps the file name
  writeFile(slugDir / "posts" / "keep-file-name.md",
    "---\ntitle: \"Something Else\"\nslugify: false\ndraft: false\n---\n\n# Something Else\n\nKeeps the file name.\n")

  let buildRes2 = execCmdEx(quoteShell(binPath) & " build " & quoteShell(slugDir))
  if buildRes2.exitCode != 0:
    fail("`stupidgreen build` (title slugs) failed: " & buildRes2.output)

  let slugOut = slugDir / "_build"
  assertFile(slugOut, "index.html")
  assertFile(slugOut, "posts/my-awesome-post/index.html")
  assertFile(slugOut, "posts/keep-file-name/index.html")
  assertContains(slugOut, "posts/my-awesome-post/index.html", "Title-derived slug")
  assertContains(slugOut, "posts/keep-file-name/index.html", "Keeps the file name")
  # the `slugify: false` post must not use its title-derived slug
  if dirExists(slugOut / "posts" / "something-else"):
    fail("`slugify: false` post should keep its file-name slug, not the title slug")

  # --- custom output dir (`--out`) ---
  let outCustom = slugDir / "nested" / "public" # does not exist yet
  let buildResOut = execCmdEx(quoteShell(binPath) & " build " & quoteShell(slugDir) &
    " --out " & quoteShell(outCustom))
  if buildResOut.exitCode != 0:
    fail("`stupidgreen build --out` failed: " & buildResOut.output)
  assertFile(outCustom, "index.html")
  assertFile(outCustom, "posts/my-awesome-post/index.html")
  assertFile(outCustom, "feed.xml")
  assertFile(outCustom, "sitemap.xml")
  assertContains(outCustom, "index.html", "StupidGreen Blog")
  assertContains(outCustom, "posts/my-awesome-post/index.html", "Title-derived slug")

  # --- asset pipeline (Squeezy CSS merge + JS bundling) ---
  # the default `new` config merges style/sweetsyntax/print CSS into
  # `assets/bundle.css` and bundles `assets/app.js` in place
  assertFile(slugOut, "assets/bundle.css")
  assertFile(slugOut, "assets/app.js")
  let bundleCss = readFile(slugOut / "assets" / "bundle.css")
  if "@media print" notin bundleCss:
    fail("bundle.css should contain the merged print.css (@media print)")
  var rawCssSize = 0
  for f in ["style.css", "sweetsyntax.css", "print.css"]:
    rawCssSize += getFileSize(slugDir / "themes" / "default" / "assets" / f)
  if getFileSize(slugOut / "assets" / "bundle.css") >= rawCssSize:
    fail("bundle.css should be smaller than the unmerged sources")
  assertContains(slugOut, "index.html", "assets/bundle.css")
  # unlisted vendored files are copied raw, byte-identical ...
  if readFile(slugOut / "assets" / "bootstrap.min.css") !=
      readFile(slugDir / "themes" / "default" / "assets" / "bootstrap.min.css"):
    fail("unlisted bootstrap.min.css must be copied raw, byte-identical")
  # ... and the merged sources remain as raw copies (old templates keep working)
  assertFile(slugOut, "assets/style.css")

  # `bundle: false` disables the pipeline entirely
  writeFile(slugConfig, readFile(slugConfig).replace("bundle: true", "bundle: false"))
  let noBundleOut = slugDir / "nobuild"
  let buildResNoBundle = execCmdEx(quoteShell(binPath) & " build " & quoteShell(slugDir) &
    " --out " & quoteShell(noBundleOut))
  if buildResNoBundle.exitCode != 0:
    fail("`stupidgreen build` (bundle: false) failed: " & buildResNoBundle.output)
  if fileExists(noBundleOut / "assets" / "bundle.css"):
    fail("bundle: false must not emit assets/bundle.css")
  assertFile(noBundleOut, "assets/style.css")
  writeFile(slugConfig, readFile(slugConfig).replace("bundle: false", "bundle: true"))

  # a listed-but-missing asset fails the build
  writeFile(slugConfig, readFile(slugConfig).replace("js: [\"app.js\"]", "js: [\"missing.js\"]"))
  let buildResMissing = execCmdEx(quoteShell(binPath) & " build " & quoteShell(slugDir))
  if buildResMissing.exitCode == 0:
    fail("`stupidgreen build` (missing asset) should fail")
  if "missing.js" notin buildResMissing.output:
    fail("missing asset error should name the file")

  # invalid JS fails the build (output validation gate)
  writeFile(slugDir / "themes" / "default" / "assets" / "bad.js", "{{{ nope")
  writeFile(slugConfig, readFile(slugConfig).replace("js: [\"missing.js\"]", "js: [\"bad.js\"]"))
  let buildResBad = execCmdEx(quoteShell(binPath) & " build " & quoteShell(slugDir))
  if buildResBad.exitCode == 0:
    fail("`stupidgreen build` (invalid JS) should fail")

  echo "OK: all stupidgreen build tests passed"
  quit(0)

when isMainModule:
  runTests()
