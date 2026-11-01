# StupidGreen - A static blog generator for cool kids!
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps

## Static asset pipeline for `stupidgreen build`, powered by Squeezy.
## The stylesheets declared under `assets.css` are merged in order into
## `assets/bundle.css` (minified); each script under `assets.js` is
## bundled independently, in place (minified). Only listed files are
## processed — everything else is left as copied. Any failure (a listed
## file missing from `assets/`, a parse/bundle error) fails the build.

import std/[os, strutils]

import pkg/squeezy
import pkg/kapsis/interactive/prompts

import ../../app/structs

const cssBundleName* = "bundle.css"
  ## Output filename for the merged stylesheet, relative to `assets/`

proc bundleBuildAssets*(assetsDir: string, cfg: AssetsSettings) =
  ## Runs the Squeezy pipeline over the merged `<output>/assets/` dir.
  if cfg.css.len > 0:
    var parts: seq[string] = @[]
    var rawSize = 0
    for rel in cfg.css:
      let path = assetsDir / rel
      if not fileExists(path):
        displayError("Asset not found: `assets/" & rel &
          "` (listed under `assets.css`)", quitProcess = true)
      let code = readFile(path)
      rawSize += code.len
      parts.add(code)
    var merged = ""
    try:
      merged = minify(parts.join("\n"), "css",
        BundleConfig(minify: true))
    except CatchableError as e:
      displayError("Could not bundle CSS into `assets/" & cssBundleName &
        "`: " & e.msg, quitProcess = true)
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
