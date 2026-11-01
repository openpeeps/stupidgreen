# StupidGreen i18n/gettext bootstrap test
#
# - `stupidgreen new` writes `storage/en.pot` into the project
# - the template parses with openparser's gettext catalog,
#   carries English headers and the expected msgids
# - `build` seeds it missing-only (translator edits are kept)
#
# (c) 2026 George Lemon | MIT License

import std/[os, osproc, strutils, tables, tempfiles]

import pkg/openparser/gettext/po

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

  let dir = createTempDir("stupidgreen_i18n_", "")
  defer: removeDir(dir)

  let newRes = execCmdEx(quoteShell(binPath) & " new " & quoteShell(dir))
  if newRes.exitCode != 0:
    fail("`stupidgreen new` failed: " & newRes.output)

  # --- the template lands in the project storage dir ---
  assertFile(dir, "storage/en.pot")
  assertContains(dir, "storage/en.pot", "Language: en")
  assertContains(dir, "storage/en.pot", "Plural-Forms:")
  assertContains(dir, "storage/en.pot", "msgid \"Search\"")
  assertContains(dir, "storage/en.pot", "msgid \"Back to Homepage\"")
  assertContains(dir, "storage/en.pot", "msgid \"Something went wrong\"")

  # --- it parses with openparser's gettext catalog ---
  let cat = openPoCatalog(dir / "storage" / "en.pot")
  if cat.entries.len < 20:
    fail("expected at least 20 entries in en.pot, got " & $cat.entries.len)
  let cc = compilePo(cat)
  close(cat)
  if cc.headers.getOrDefault("Language", "") != "en":
    fail("expected `Language: en` header in en.pot")
  # empty msgstr falls back to msgid (English is the source language)
  if translate(cc, "Search") != "Search":
    fail("expected msgid fallback for \"Search\"")
  if translate(cc, "Back to Homepage") != "Back to Homepage":
    fail("expected msgid fallback for \"Back to Homepage\"")
  if translate(cc, "Older") != "Older":
    fail("expected msgid fallback for \"Older\"")
  # plural forms resolve through the header's plural expression
  if ntranslate(cc, "{count} minute ago", "{count} minutes ago", 1) != "{count} minute ago":
    fail("expected singular minute form for n=1")
  if ntranslate(cc, "{count} minute ago", "{count} minutes ago", 5) != "{count} minutes ago":
    fail("expected plural minute form for n=5")
  # unknown msgids fall back to themselves
  if translate(cc, "no such string") != "no such string":
    fail("expected msgid fallback for unknown strings")

  # --- build seeds missing-only: translator edits are kept ---
  let potPath = dir / "storage" / "en.pot"
  writeFile(potPath, readFile(potPath) & "\n# translator note\n")

  # --- end-to-end translation: Romanian catalog + content ---
  let configPath = dir / "stupidgreen.config.yaml"
  writeFile(configPath, readFile(configPath)
    .replace("  enable: false\n  default: \"en\"\n  supported: [\"en\"]",
      "  enable: true\n  default: \"en\"\n  supported: [\"en\", \"ro\"]")
    .replace("per_page: 10", "per_page: 1"))
  writeFile(dir / "posts" / "hello-world.ro.md",
    "---\ntitle: \"Salut Lume\"\ndate: \"\"\ntags: [stupidgreen]\n" &
    "categories: []\ndraft: false\n---\n\nSalut de pe blog!\n")
  writeFile(dir / "posts" / "extra.md",
    "---\ntitle: \"Extra Post\"\ndate: \"\"\ntags: [stupidgreen]\n" &
    "categories: []\ndraft: false\n---\n\nAn extra post.\n")
  writeFile(dir / "posts" / "extra.ro.md",
    "---\ntitle: \"Articol Extra\"\ndate: \"\"\ntags: [stupidgreen]\n" &
    "categories: []\ndraft: false\n---\n\nUn articol in plus.\n")
  writeFile(dir / "storage" / "ro.po",
    "# Romanian translation.\n" &
    "msgid \"\"\n" &
    "msgstr \"\"\n" &
    "\"Project-Id-Version: StupidGreen 0.1.0\\n\"\n" &
    "\"Language: ro\\n\"\n" &
    "\"Content-Type: text/plain; charset=UTF-8\\n\"\n" &
    "\"Plural-Forms: nplurals=2; plural=(n != 1);\\n\"\n" &
    "\n" &
    "#: src/themes/default/views/index.timl\n" &
    "msgid \"Latest posts\"\n" &
    "msgstr \"Ultimele articole\"\n" &
    "\n" &
    "#: src/themes/default/views/search.timl\n" &
    "msgid \"Search\"\n" &
    "msgstr \"Caută\"\n" &
    "\n" &
    "#: src/themes/default/partials/header.timl\n" &
    "msgid \"Search the blog...\"\n" &
    "msgstr \"Caută în blog...\"\n" &
    "\n" &
    "#: src/themes/default/views/tag.timl\n" &
    "msgid \"Tag: {tag}\"\n" &
    "msgstr \"Etichetă: {tag}\"\n" &
    "\n" &
    "#: src/themes/default/views/tag.timl\n" &
    "msgid \"{count} post\"\n" &
    "msgid_plural \"{count} posts\"\n" &
    "msgstr[0] \"{count} articol\"\n" &
    "msgstr[1] \"{count} articole\"\n" &
    "\n" &
    "#: src/themes/default/partials/pagination.timl\n" &
    "msgid \"Page {page} of {total}\"\n" &
    "msgstr \"Pagina {page} din {total}\"\n")

  let buildRes = execCmdEx(quoteShell(binPath) & " build " & quoteShell(dir))
  if buildRes.exitCode != 0:
    fail("`stupidgreen build` failed: " & buildRes.output)
  assertContains(dir, "storage/en.pot", "translator note")
  let outDir = dir / "_build"

  # --- translated strings replace the English source ---
  assertContains(outDir, "ro/index.html", "Ultimele articole")
  assertContains(outDir, "ro/index.html", "Caută în blog...")
  assertNotContains(outDir, "ro/index.html", "Latest posts")
  assertContains(outDir, "index.html", "Latest posts")
  assertContains(outDir, "posts/hello-world/index.html", "Published by")

  # --- placeholders are substituted in both languages ---
  assertContains(outDir, "ro/tags/stupidgreen/index.html", "Etichetă: stupidgreen")
  assertContains(outDir, "tags/stupidgreen/index.html", "Tag: stupidgreen")
  assertContains(outDir, "ro/tags/stupidgreen/index.html", "2 articole")
  assertContains(outDir, "tags/stupidgreen/index.html", "2 posts")
  assertContains(outDir, "ro/page/2/index.html", "Pagina 2 din 2")
  assertContains(outDir, "page/2/index.html", "Page 2 of 2")

  echo "OK: all stupidgreen i18n tests passed"
  quit(0)

when isMainModule:
  runTests()
