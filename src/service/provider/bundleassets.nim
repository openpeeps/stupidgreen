# StupidGreen - A static blog generator for cool kids!
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps

## Static asset pipeline for `stupidgreen build` and `stupidgreen run`,
## powered by Squeezy. Runs over a merged view of all theme/project
## assets: every stylesheet is merged into `bundle.css` (custom styles
## minified, `.min.css` vendored files inlined raw, first) and every
## script into `bundle.js` (each minified on its own, exports stripped,
## then concatenated). Files named under `assets.css`/`assets.js` come
## first, in order; the rest is discovered automatically. Any failure
## (a listed file missing, a parse/bundle error) fails the command.

import std/[os, strutils, algorithm]

import pkg/squeezy
import pkg/squeezy/bundle/js/minifier as jsminifier
import pkg/kapsis/interactive/prompts

import ../../app/structs

const cssBundleName* = "bundle.css"
  ## Output filename for the merged stylesheet, relative to `assets/`

const jsBundleName* = "bundle.js"
  ## Output filename for the merged script, relative to `assets/`

proc stripJsSourceMapRef*(code: string): string =
  ## Removes `//# sourceMappingURL=...` lines. Vendored `.min.js`
  ## files ship one pointing at their own `.map`; once inlined into
  ## `bundle.js` the reference is stale, so it is dropped.
  result = code
  while true:
    let s = result.find("//# sourceMappingURL=")
    if s < 0: break
    var e = result.find("\n", s)
    if e < 0:
      result = result[0 ..< s]
      break
    result = result[0 ..< s] & result[e .. ^1]

proc resolveCssInputs*(assetsDir: string, listed: seq[string]): seq[string] =
  ## Full CSS input list for the merge. `listed` files come first, in
  ## order (a missing one fails the command); then every other `*.css`
  ## under `assetsDir` is appended automatically — vendored `*.min.css`
  ## first, then the rest, each alphabetical. `bundle.css` itself is never
  ## an input (a previous run's bundle may sit in the public dir), and
  ## hidden files are skipped like the asset copy does.
  result = @[]
  for rel in listed:
    if not fileExists(assetsDir / rel):
      displayError("Asset not found: `assets/" & rel &
        "` (listed under `assets.css`)", quitProcess = true)
    if rel notin result:
      result.add(rel)
  var mins, rest: seq[string] = @[]
  for fpath in walkDirRec(assetsDir,
      yieldFilter = {pcFile, pcLinkToFile}):
    if not fileExists(fpath):
      continue
    let rel = relativePath(fpath, assetsDir)
    if extractFilename(rel).startsWith("."):
      continue
    if rel == cssBundleName or rel in result:
      continue
    if not rel.endsWith(".css"):
      continue
    if rel.endsWith(".min.css"):
      mins.add(rel)
    else:
      rest.add(rel)
  result.add(mins.sorted())
  result.add(rest.sorted())

proc resolveJsInputs*(assetsDir: string, listed: seq[string]): seq[string] =
  ## Full JS input list for the merge. `listed` files come first, in
  ## order (a missing one fails the command); then every other `*.js`
  ## under `assetsDir` is appended automatically — vendored `*.min.js`
  ## first, then the rest, each alphabetical. `bundle.js` itself and
  ## sourcemaps are never inputs (a previous run's bundle may sit in the
  ## public dir), and hidden files are skipped like the asset copy does.
  result = @[]
  for rel in listed:
    if not fileExists(assetsDir / rel):
      displayError("Asset not found: `assets/" & rel &
        "` (listed under `assets.js`)", quitProcess = true)
    if rel notin result:
      result.add(rel)
  var mins, rest: seq[string] = @[]
  for fpath in walkDirRec(assetsDir,
      yieldFilter = {pcFile, pcLinkToFile}):
    if not fileExists(fpath):
      continue
    let rel = relativePath(fpath, assetsDir)
    if extractFilename(rel).startsWith("."):
      continue
    if rel == jsBundleName or rel in result:
      continue
    if not rel.endsWith(".js") or rel.endsWith(".js.map"):
      continue
    if rel.endsWith(".min.js"):
      mins.add(rel)
    else:
      rest.add(rel)
  result.add(mins.sorted())
  result.add(rest.sorted())

proc stripSourceMapRef*(code: string): string =
  ## Removes `/*# sourceMappingURL=... */` comments. Vendored `.min.css`
  ## files ship one pointing at their own `.map`; once inlined into
  ## `bundle.css` the reference is stale, so it is dropped.
  result = code
  while true:
    let s = result.find("/*# sourceMappingURL=")
    if s < 0: break
    let e = result.find("*/", s)
    if e < 0: break
    result = result[0 ..< s] & result[e + 2 .. ^1]

proc bundleBuildAssets*(assetsDir: string, cfg: AssetsSettings) =
  ## Runs the Squeezy pipeline over a merged `assets/` dir — the build
  ## output dir for `build`, the public `assets/` dir for `run`.
  let cssInputs = resolveCssInputs(assetsDir, cfg.css)
  if cssInputs.len > 0:
    var outParts: seq[string] = @[]
    var customBuf: seq[string] = @[]
    var rawSize = 0
    proc flushCustom() =
      if customBuf.len == 0: return
      var minified = ""
      try:
        minified = minify(customBuf.join("\n"), "css",
          BundleConfig(minify: true))
      except CatchableError as e:
        displayError("Could not bundle CSS into `assets/" & cssBundleName &
          "`: " & e.msg, quitProcess = true)
      outParts.add(minified)
      customBuf = @[]
    for rel in cssInputs:
      let path = assetsDir / rel
      rawSize += getFileSize(path).int
      if rel.endsWith(".min.css"):
        # Already minified (e.g. vendored `bootstrap.min.css`): inline it
        # raw to preserve bytes and skip re-serializing a huge file
        # through the parser. Listed order is kept, so keep these first
        # (cascade + `@charset` must stay at the top).
        flushCustom()
        outParts.add(readFile(path).strip().stripSourceMapRef().strip())
      else:
        customBuf.add(readFile(path))
    flushCustom()
    let merged = outParts.join("\n")
    # Squeezy degrades to raw passthrough instead of raising on some
    # inputs, so validate the emitted output: a broken bundle must
    # fail the build, never ship silently.
    let cssErrors =
      try: validateCss(merged)
      except CatchableError as e:
        displayError("Could not validate `assets/" & cssBundleName &
          "`: " & e.msg, quitProcess = true)
        @["validation crashed"]
    if cssErrors.len > 0:
      displayError("Bundled CSS failed validation (`assets/" &
        cssBundleName & "`):\n" & cssErrors.join("\n"), quitProcess = true)
    writeFile(assetsDir / cssBundleName, merged)
    display("Bundled CSS: " & cssBundleName &
      " (" & $merged.len & " bytes, was " & $rawSize & " bytes)")
  proc emitJs(rel, path, code: string, rawSize: int64) =
    ## Validates and writes one bundled script. Squeezy degrades to raw
    ## passthrough instead of raising on some inputs, so the emitted
    ## output is validated: a broken bundle fails the build, never ships.
    let jsErrors =
      try: validateJs(code)
      except CatchableError as e:
        displayError("Could not validate `assets/" & rel &
          "`: " & e.msg, quitProcess = true)
        @["validation crashed"]
    if jsErrors.len > 0:
      displayError("Bundled JS failed validation (`assets/" & rel &
        "`, keeping the raw file is not an option):\n" &
        jsErrors.join("\n"), quitProcess = true)
    writeFile(path, code)
    display("Bundled JS: " & rel &
      " (" & $code.len & " bytes, was " & $rawSize & " bytes)")

  block:
    let jsInputs = resolveJsInputs(assetsDir, cfg.js)
    if jsInputs.len > 0:
      # one script: every source is minified on its own (exports/imports
      # stripped — these are classic page scripts, not ES modules) and the
      # outputs are concatenated in input order into `assets/bundle.js`.
      # Minifying per file keeps each parse small and proven; the merged
      # bundle is validated as a whole below.
      let genOpts = JsGenOptions(minify: true, mangle: false,
        stripExports: true)
      var parts: seq[string] = @[]
      var rawSize = 0
      for rel in jsInputs:
        let path = assetsDir / rel
        rawSize += getFileSize(path).int
        if rel.endsWith(".min.js"):
          # already minified: inline raw (stale map refs stripped)
          parts.add(readFile(path).strip().stripJsSourceMapRef().strip())
        else:
          var code = ""
          try:
            code = jsminifier.minifyJs(readFile(path), genOpts).code
          except CatchableError as e:
            displayError("Could not bundle `assets/" & rel &
              "`: " & e.msg, quitProcess = true)
          parts.add(code)
      let code = parts.join("\n;\n") & "\n"
      emitJs(jsBundleName, assetsDir / jsBundleName, code, rawSize.int64)
