# StupidGreen integration test: language switcher
#
# Enables the `languages` feature on a scaffolded project, adds Romanian
# translations (`*.ro.md`) and verifies the generated static site:
# prefixed URLs, per-language indexes/feeds/archives, the header
# switcher, hreflang links, feed filtering and the no-fallback rule
# (untranslated content produces no `<lang>` output).
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

proc assertNotContains(project, rel, needle: string) =
  if not fileExists(project / rel):
    fail("expected file does not exist: " & rel)
  let content = readFile(project / rel)
  if needle in content:
    fail("unexpected `" & needle & "` in " & rel)

proc runTests() =
  binPath = getCurrentDir() / "build" / "stupidgreen"
  if not fileExists(binPath):
    fail("StupidGreen binary not found. Run `clue build` first: " & binPath)

  let dir = createTempDir("stupidgreen_langs_", "")
  defer: removeDir(dir)

  let newRes = execCmdEx(quoteShell(binPath) & " new " & quoteShell(dir))
  if newRes.exitCode != 0:
    fail("`stupidgreen new` failed: " & newRes.output)

  # enable the languages feature (opt-in)
  let configPath = dir / "stupidgreen.config.yaml"
  writeFile(configPath, readFile(configPath).replace(
    "  enable: false\n  default: \"en\"\n  supported: [\"en\"]",
    "  enable: true\n  default: \"en\"\n  supported: [\"en\", \"ro\"]"))
  assertContains(dir, "stupidgreen.config.yaml", "enable: true")

  # Romanian translations (same base names + `.ro` suffix)
  writeFile(dir / "posts" / "hello-world.ro.md",
    "---\ntitle: \"Salut Lume\"\ndate: \"\"\ntags: [stupidgreen]\n" &
    "categories: []\ndraft: false\n---\n\nSalut de pe blogul **StupidGreen**!\n")
  writeFile(dir / "pages" / "about.ro.md",
    "---\ntitle: \"Despre\"\ndraft: false\n---\n\n# Despre\n\nPagina in romana.\n")
  writeFile(dir / "pages" / "llms.ro.md",
    "---\ntitle: \"LLM\"\ndraft: false\n---\n\nText in romana pentru LLM.\n")
  # a post with no translation (no `/ro` output must be generated for it)
  writeFile(dir / "posts" / "only-english.md",
    "---\ntitle: \"Only English\"\ndate: \"\"\ntags: []\n" &
    "categories: []\ndraft: false\n---\n\nNo translation for this one.\n")

  let buildRes = execCmdEx(quoteShell(binPath) & " build " & quoteShell(dir))
  if buildRes.exitCode != 0:
    fail("`stupidgreen build` failed: " & buildRes.output)
  let outDir = dir / "_build"

  # --- translated routes exist ---
  assertFile(outDir, "ro/index.html")
  assertFile(outDir, "ro/posts/hello-world/index.html")
  assertFile(outDir, "ro/about/index.html")
  assertFile(outDir, "ro/feed.xml")
  assertFile(outDir, "ro/llms.txt")
  assertFile(outDir, "ro/tags/stupidgreen/index.html")
  assertFile(outDir, "tags/stupidgreen/index.html")

  # --- content is actually translated ---
  assertContains(outDir, "ro/index.html", "Salut Lume")
  assertContains(outDir, "ro/posts/hello-world/index.html", "Salut de pe blog")
  assertContains(outDir, "ro/about/index.html", "Despre")
  assertContains(outDir, "ro/llms.txt", "romana")
  assertContains(outDir, "llms.txt", "LLM-friendly access")

  # --- default language output is untouched by translations ---
  assertContains(outDir, "index.html", "Hello World")
  assertNotContains(outDir, "index.html", "Salut Lume")
  assertContains(outDir, "posts/hello-world/index.html", "Welcome to your brand new")

  # --- header switcher links both ways ---
  assertContains(outDir, "posts/hello-world/index.html", "language-switcher")
  assertContains(outDir, "posts/hello-world/index.html", "/ro/posts/hello-world")
  assertContains(outDir, "ro/posts/hello-world/index.html", "/posts/hello-world")
  assertContains(outDir, "ro/about/index.html", "hreflang")

  # --- no fallback output for untranslated content ---
  if dirExists(outDir / "ro" / "posts" / "only-english"):
    fail("untranslated post must not produce `/ro` output")
  assertContains(outDir, "posts/only-english/index.html", "No translation")

  # --- feeds stay on their own language ---
  assertContains(outDir, "ro/feed.xml", "Salut Lume")
  assertNotContains(outDir, "feed.xml", "Salut Lume")
  assertContains(outDir, "feed.xml", "Hello World")

  # --- sitemap lists every language with hreflang alternates ---
  assertContains(outDir, "sitemap.xml", "/ro/about")
  assertContains(outDir, "sitemap.xml", "/ro/posts/hello-world")
  assertContains(outDir, "sitemap.xml", "hreflang=\"ro\"")

  # --- search index carries the language of each entry ---
  assertContains(outDir, "results.json", "\"lang\":\"ro\"")
  assertContains(outDir, "results.json", "\"lang\":\"\"")

  echo "OK: all stupidgreen language switcher tests passed"
  quit(0)

when isMainModule:
  runTests()
