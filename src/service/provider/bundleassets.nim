# StupidGreen - A static blog generator for cool kids!
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps

## Static asset pipeline for `stupidgreen build` and `stupidgreen run`,
## powered by Squeezy.
## The stylesheets declared under `assets.css` are merged in order into
## `assets/bundle.css` (custom styles minified, `.min.css` vendored files
## inlined raw); each script under `assets.js` is bundled independently,
## in place (minified). Only listed files are processed — everything else
## is left as copied. Any failure (a listed file missing from `assets/`,
## a parse/bundle error) fails the command.

import std/[os, strutils]

import pkg/squeezy
import pkg/kapsis/interactive/prompts

import ../../app/structs

const cssBundleName* = "bundle.css"
  ## Output filename for the merged stylesheet, relative to `assets/`

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
  if cfg.css.len > 0:
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
    for rel in cfg.css:
      let path = assetsDir / rel
      if not fileExists(path):
        displayError("Asset not found: `assets/" & rel &
          "` (listed under `assets.css`)", quitProcess = true)
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

  if cfg.js.len > 0:
    let jsCfg = BundleConfig(minify: true, mangle: cfg.mangle,
      sourceMap: cfg.sourcemap)
    for rel in cfg.js:
      let path = assetsDir / rel
      if not fileExists(path):
        displayError("Asset not found: `assets/" & rel &
          "` (listed under `assets.js`)", quitProcess = true)
      let rawSize = getFileSize(path)
      if cfg.sourcemap:
        # raw bundle first, then a single minify pass so the map
        # covers the whole bundle (same approach as the Squeezy CLI)
        var raw = ""
        try:
          raw = bundle(path, BundleConfig(minify: false))
        except CatchableError as e:
          displayError("Could not bundle `assets/" & rel &
            "`: " & e.msg, quitProcess = true)
        var res: MinifyResult
        try:
          res = minifyWithSourceMap(raw, "js", jsCfg,
            extractFilename(path))
        except CatchableError as e:
          displayError("Could not minify `assets/" & rel &
            "`: " & e.msg, quitProcess = true)
        emitJs(rel, path, res.code & "\n//# sourceMappingURL=" &
          extractFilename(path) & ".map\n", rawSize)
        writeFile(path & ".map", res.sourceMapRaw)
      else:
        var code = ""
        try:
          code = bundle(path, jsCfg)
        except CatchableError as e:
          displayError("Could not bundle `assets/" & rel &
            "`: " & e.msg, quitProcess = true)
        emitJs(rel, path, code, rawSize)
