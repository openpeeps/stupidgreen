# StupidGreen - A static blog generator for cool kids!
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps

import std/[macros, json, strutils, os,
        httpcore, times, options, tables]

import pkg/supranim/support/slug
import pkg/supranim/core/[services, paths]
import pkg/vancode/interpreter/value
import pkg/[tim, iconim, kapsis/framework]
import pkg/openparser/json
import pkg/openparser/gettext/po

import pkg/kapsis/interactive/prompts

export HttpCode, render, `&*`
export times.now, times.format

import ../../app/structs
import ./logger

initService Tim[Global]:
  # A singleton service that wraps the Tim Engine
  # and provides a simple interface to render HTML pages
  backend do:
    var timInstance*: TimEngine
    var timBaseUrl* = ""
      ## Base URL prepended by the `url()` template function. Empty in
      ## dev (the server resolves root-relative paths itself); the
      ## normalized `metadata.url` in builds (absolute asset links).
    var timRenderLang* {.threadvar.}: string
      ## Current render language (e.g. `"fr"`), set per render from
      ## `local["currentLang"]`. Lets `siteUrl` prefix content URLs
      ## with `/<lang>` for non-default languages.

    proc siteUrl*(path: string): string =
      ## Resolves a root-relative path (`/assets/bundle.css`) against the
      ## site base URL. Absolute URLs pass through untouched; a missing
      ## leading slash is added (empty path resolves to the homepage `/`).
      ## In dev the base is empty, so plain root-relative paths are
      ## returned (served by the dev server). When the languages feature
      ## is active and the current render language is non-default,
      ## content paths gain a `/<lang>` prefix (`/search` -> `/fr/search`);
      ## `/assets/*` never does (static files live unprefixed).
      if isAbsoluteUrl(path):
        return path
      let p =
        if path.len == 0: "/"
        elif path[0] != '/': "/" & path
        else: path
      if not globalStupidGreenConfig.languagesEnabled():
        return timBaseUrl & p
      let cur = timRenderLang
      if cur.len == 0 or cur == globalStupidGreenConfig.defaultLangCode():
        return timBaseUrl & p
      if p == "/":
        return timBaseUrl & "/" & cur
      if p == "/assets" or p.startsWith("/assets/"):
        return timBaseUrl & p
      for code in globalStupidGreenConfig.supportedLangCodes():
        if p == "/" & code or p.startsWith("/" & code & "/"):
          return timBaseUrl & p
      result = timBaseUrl & "/" & cur & p

    var timI18nCatalogs*: Table[string, PoCompiledCatalog]
      ## Compiled gettext catalogs per language code (`en` from
      ## `storage/en.pot`, others from `storage/<lang>.po`). Read-only
      ## after `loadI18n`, so concurrent renders share them safely.

    proc loadI18n*(projectPath: string) =
      ## Loads gettext catalogs from `<project>/storage` into memory:
      ## `en.pot` as the English source catalog and every `<lang>.po`
      ## as its translation. Missing or invalid files are skipped with
      ## a warning; lookups then fall back to `msgid`.
      timI18nCatalogs = initTable[string, PoCompiledCatalog]()
      proc loadFile(lang, path: string) =
        try:
          let cat = openPoCatalog(path)
          timI18nCatalogs[lang] = compilePo(cat)
          close(cat)
        except PoParseError as e:
          displayWarning("Skipping invalid gettext file `" & path & "`: " & e.msg)
        except IOError as e:
          displayWarning("Skipping unreadable gettext file `" & path & "`: " & e.msg)
      let storageDir = projectPath / "storage"
      let pot = storageDir / "en.pot"
      if fileExists(pot):
        loadFile("en", pot)
      if dirExists(storageDir):
        for kind, path in walkDir(storageDir):
          if kind == pcFile and path.endsWith(".po"):
            let code = extractFilename(path)[0 .. ^4].strip().toLowerAscii()
            if code.len > 0 and code notin timI18nCatalogs:
              loadFile(code, path)

    proc i18nTranslate*(msgid: string): string =
      ## Returns the `msgid` translation for the current render language
      ## (`timRenderLang`), falling back through the default language to
      ## English and finally to `msgid` itself. Empty `msgstr` entries
      ## (as in `en.pot`) also fall back to `msgid`, since English is
      ## the source language.
      let cur = timRenderLang
      if cur.len > 0 and timI18nCatalogs.hasKey(cur):
        return translate(timI18nCatalogs[cur], msgid)
      let defLang = globalStupidGreenConfig.defaultLangCode()
      if defLang != cur and timI18nCatalogs.hasKey(defLang):
        return translate(timI18nCatalogs[defLang], msgid)
      if timI18nCatalogs.hasKey("en"):
        return translate(timI18nCatalogs["en"], msgid)
      msgid

    proc i18nNTranslate*(singular, plural: string, n: int): string =
      ## Plural-aware `i18nTranslate`: selects the catalog form with the
      ## header's plural expression, falling back like the singular one.
      let cur = timRenderLang
      if cur.len > 0 and timI18nCatalogs.hasKey(cur):
        return ntranslate(timI18nCatalogs[cur], singular, plural, n)
      let defLang = globalStupidGreenConfig.defaultLangCode()
      if defLang != cur and timI18nCatalogs.hasKey(defLang):
        return ntranslate(timI18nCatalogs[defLang], singular, plural, n)
      if timI18nCatalogs.hasKey("en"):
        return ntranslate(timI18nCatalogs["en"], singular, plural, n)
      (if n == 1: singular else: plural)

    proc timArgToStr(v: value.Value): string =
      ## Stringifies a Tim foreign-proc argument for `{placeholder}`
      ## substitution. Non-scalar values (objects, arrays, procs, nil)
      ## contribute an empty string.
      if v.isNil:
        return ""
      case v.typeId
      of tyString:
        v.stringVal[]
      of tyInt:
        $v.intVal
      of tyFloat:
        $v.floatVal
      of tyBool:
        $v.boolVal
      of tyJsonStorage:
        let j = v.jsonVal
        if j.isNil:
          return ""
        case j.kind
        of JString: j.getStr()
        of JInt: $j.getInt()
        of JFloat: $j.getFloat()
        of JBool: $j.getBool()
        of JNull: ""
        else: $j
      else:
        ""

    proc timVarsToJson(v: value.Value): JsonNode =
      ## Converts an `i18n()` vars argument to a JSON object: either a
      ## Tim object literal (`{page: ...}`) or a `JsonNode` (e.g. `$this`).
      result = newJObject()
      if v.isNil:
        return
      if v.typeId == tyJsonStorage:
        if not v.jsonVal.isNil and v.jsonVal.kind == JObject:
          for k, val in v.jsonVal.pairs:
            result[k] = val
        return
      if v.typeId != tyObjectStorage:
        return
      let o = v.objectVal
      if o.isNil or o.isForeign:
        return
      for i in 0 ..< min(o.keys.len, o.fields.len):
        result[o.keys[i]] = %timArgToStr(toValue(o.fields[i]))

    proc i18nApplyVars*(s: string, vars: JsonNode): string =
      ## Replaces `{name}` placeholders in `s` with the matching `vars`
      ## entries. Unknown placeholders are left untouched.
      result = s
      if vars.isNil or vars.kind != JObject:
        return
      for k, val in vars.pairs:
        let valStr =
          case val.kind
          of JString: val.getStr()
          of JInt: $val.getInt()
          of JFloat: $val.getFloat()
          of JBool: $val.getBool()
          of JNull: ""
          else: $val
        result = result.replace("{" & k & "}", valStr)

    Icon.init(
      source = storagePath / "icons",
      default = "filled",
      stripAttrs = %*[]
    )

    proc init*(src, output, basePath: string; global = newJObject();
                activeTheme = "default", fallbackTheme = "default") =
      ## Initialize Tim Engine as a singleton service with theme support.
      ## Templates resolve from `<basePath>/<src>/<activeTheme>` with
      ## fallback to `<basePath>/<src>/<fallbackTheme>`.
      logger("Service Tim: Initializing Tim Engine (backend + frontend)")
      timInstance = newTim(
        src = src,
        output = output,
        basePath = basePath,
        globalData = global,
        enableThemes = true,
        activeThemeName = activeTheme,
        fallbackThemeName = fallbackTheme
      )

      # predefine foreign functions
      timInstance.userScript.addProc("slugify", @[paramDef("s", ttyString)], ttyString,
        proc (args: StackView, argc: int): value.Value =
          return initValue(slugify(args[0].stringVal[]))
        )

      timInstance.userScript.addProc("icon", @[paramDef("name", ttyString)], ttyString,
        proc (args: StackView, argc: int): value.Value =
          let iconName = args[0].stringVal[]
          return initValue($icon(iconName))
        )

      timInstance.userScript.addProc("url", @[paramDef("path", ttyString)], ttyString,
        proc (args: StackView, argc: int): value.Value =
          return initValue(siteUrl(args[0].stringVal[]))
      )
      timInstance.userScript.addProc("url", @[paramDef("path", ttyJson)], ttyString,
        proc (args: StackView, argc: int): value.Value =
          var p = ""
          let v = args[0].jsonVal
          if not v.isNil:
            p = if v.kind == JString: v.getStr() else: $v
          return initValue(siteUrl(p))
      )

      timInstance.userScript.addProc("i18n", @[paramDef("msgid", ttyString)], ttyString,
        proc (args: StackView, argc: int): value.Value =
          return initValue(i18nTranslate(args[0].stringVal[]))
      )
      timInstance.userScript.addProc("i18n", @[paramDef("msgid", ttyString), paramDef("vars", ttyObject)], ttyString,
        proc (args: StackView, argc: int): value.Value =
          return initValue(i18nApplyVars(i18nTranslate(args[0].stringVal[]), timVarsToJson(args[1])))
      )
      timInstance.userScript.addProc("i18n", @[paramDef("singular", ttyString), paramDef("plural", ttyString), paramDef("n", ttyInt)], ttyString,
        proc (args: StackView, argc: int): value.Value =
          return initValue(i18nNTranslate(args[0].stringVal[], args[1].stringVal[], int(args[2].intVal)))
      )
      timInstance.userScript.addProc("i18n", @[paramDef("singular", ttyString), paramDef("plural", ttyString), paramDef("n", ttyInt), paramDef("vars", ttyObject)], ttyString,
        proc (args: StackView, argc: int): value.Value =
          let n = int(args[2].intVal)
          var vars = timVarsToJson(args[3])
          if not vars.hasKey("count"):
            vars["count"] = %n
          return initValue(i18nApplyVars(i18nNTranslate(args[0].stringVal[], args[1].stringVal[], n), vars))
      )

      timBaseUrl = "" # dev serves root-relative paths itself

      tim.initCommonStorage:
        {
          "path": req.getUrl(),
          "currentYear": now().format("yyyy"),
          "hasMarkdownSync": enableBrowserSync,
          "site": {
            "title": globalStupidGreenConfig.metadata.title.get("StupidGreen"),
            "url": globalStupidGreenConfig.metadata.url,
            "baseUrl": "",
            "logo": globalStupidGreenConfig.metadata.logo.get("/assets/stupidgreen.png"),
            "hasLogo": globalStupidGreenConfig.metadata.logo.isSome(),
            "hasNotifications": globalStupidGreenConfig.header.notification.isSome()
          }
        }

      timInstance.precompile()

    proc getTimInstance*: TimEngine =
      # Returns the singleton instance of the Tim Engine
      if timInstance == nil:
        raise newException(ValueError, "Tim Engine not initialized")
      return timInstance

    proc buildSetup*(src, output, basePath: string; global = newJObject();
                     activeTheme = "default", fallbackTheme = "default") =
      echo "  Building Tim Engine templates..."
      timInstance = newTim(
        src = src,
        output = output,
        basePath = basePath,
        globalData = global,
        enableThemes = true,
        activeThemeName = activeTheme,
        fallbackThemeName = fallbackTheme
      )
      timInstance.userScript.addProc("slugify", @[paramDef("s", ttyString)], ttyString,
        proc (args: StackView, argc: int): value.Value =
          return initValue(slugify(args[0].stringVal[]))
      )
      timInstance.userScript.addProc("icon", @[paramDef("name", ttyString)], ttyString,
        proc (args: StackView, argc: int): value.Value =
          let iconName = args[0].stringVal[]
          return initValue($icon(iconName))
      )
      timInstance.userScript.addProc("url", @[paramDef("path", ttyString)], ttyString,
        proc (args: StackView, argc: int): value.Value =
          return initValue(siteUrl(args[0].stringVal[]))
      )
      timInstance.userScript.addProc("url", @[paramDef("path", ttyJson)], ttyString,
        proc (args: StackView, argc: int): value.Value =
          var p = ""
          let v = args[0].jsonVal
          if not v.isNil:
            p = if v.kind == JString: v.getStr() else: $v
          return initValue(siteUrl(p))
      )
      timInstance.userScript.addProc("i18n", @[paramDef("msgid", ttyString)], ttyString,
        proc (args: StackView, argc: int): value.Value =
          return initValue(i18nTranslate(args[0].stringVal[]))
      )
      timInstance.userScript.addProc("i18n", @[paramDef("msgid", ttyString), paramDef("vars", ttyObject)], ttyString,
        proc (args: StackView, argc: int): value.Value =
          return initValue(i18nApplyVars(i18nTranslate(args[0].stringVal[]), timVarsToJson(args[1])))
      )
      timInstance.userScript.addProc("i18n", @[paramDef("singular", ttyString), paramDef("plural", ttyString), paramDef("n", ttyInt)], ttyString,
        proc (args: StackView, argc: int): value.Value =
          return initValue(i18nNTranslate(args[0].stringVal[], args[1].stringVal[], int(args[2].intVal)))
      )
      timInstance.userScript.addProc("i18n", @[paramDef("singular", ttyString), paramDef("plural", ttyString), paramDef("n", ttyInt), paramDef("vars", ttyObject)], ttyString,
        proc (args: StackView, argc: int): value.Value =
          let n = int(args[2].intVal)
          var vars = timVarsToJson(args[3])
          if not vars.hasKey("count"):
            vars["count"] = %n
          return initValue(i18nApplyVars(i18nNTranslate(args[0].stringVal[], args[1].stringVal[], n), vars))
      )
      timBaseUrl = globalStupidGreenConfig.metadata.url
      timInstance.precompile()

    proc buildRender*(view, path: string, local: JsonNode): string =
      if timInstance == nil:
        raise newException(ValueError, "Tim Engine not initialized. Call buildSetup first.")
      timRenderLang =
        if not local.isNil and local.hasKey("currentLang") and
            local["currentLang"].kind == JString:
          local["currentLang"].getStr()
        else: ""
      var data = newJObject()
      data["path"] = newJString(path)
      data["currentYear"] = newJString(now().format("yyyy"))
      data["hasMarkdownSync"] = newJBool(false)
      var site = newJObject()
      site["title"] = newJString(globalStupidGreenConfig.metadata.title.get("StupidGreen"))
      site["url"] = newJString(globalStupidGreenConfig.metadata.url)
      site["baseUrl"] = newJString(globalStupidGreenConfig.metadata.url)
      site["logo"] = newJString(globalStupidGreenConfig.metadata.logo.get("/assets/stupidgreen.png"))
      site["hasLogo"] = newJBool(globalStupidGreenConfig.metadata.logo.isSome())
      site["hasNotifications"] = newJBool(globalStupidGreenConfig.header.notification.isSome())
      data["site"] = site
      for key, val in local.pairs:
        data[key] = val
      result = render(timInstance, view, "base", data)

    proc hasView*(view: string): bool =
      ## Whether a Tim view template exists in the active or fallback theme
      if timInstance == nil:
        return false
      result = timInstance.getView(view) != nil

    proc resolvePageView*(layout, defaultView: string): string =
      ## Resolves a front-matter `layout` value to a renderable Tim view.
      ## Returns `defaultView` when the layout is empty, contains unsafe
      ## characters or traversal segments, or has no matching template
      ## in either the active or the fallback theme.
      var parts: seq[string] = @[]
      for raw in layout.strip().split({'/', '.'}):
        let seg = raw.strip()
        if seg.len == 0 or seg == "..":
          return defaultView
        for c in seg:
          if c notin {'a'..'z', 'A'..'Z', '0'..'9', '-', '_'}:
            return defaultView
        parts.add(seg)
      if parts.len == 0:
        return defaultView
      let name = parts.join("/")
      if hasView(name):
        return name
      return defaultView

  client do:

    proc error*(message: string, exception: ref Exception) =
      echo message
      echo exception.getStackTrace()

    template render*(view: string, layout: string = "base",
                      httpCode = Http200, local: JsonNode = nil): untyped =
      ## Renders a Tim template and sends it as an HTTP response.
      ## It must be used within a route handler (controller).
      ## `local` is bound once: callers often pass template expansions
      ## (`indexLocal(...)`), which must not be evaluated twice.
      block:
        let renderLocal: JsonNode = local
        timRenderLang =
          if not renderLocal.isNil and renderLocal.hasKey("currentLang") and
              renderLocal["currentLang"].kind == JString:
            renderLocal["currentLang"].getStr()
          else: ""
        try:
          let output = render(timInstance, view, layout, renderLocal)
          respond(httpCode, output)
        except TimEngineError as e:
          displayError("<services.tim> " & e.msg)
          respond(Http500, render(timInstance, "errors.5xx", layout, data = &*{
            "post": {
              "meta": {
                "title": "Something went wrong",
                "description": "The page you are looking for does not exist."
              },
            },
            "config": globalStupidGreenConfig,
            "currentLang": "",
            "siteLangs": newJArray(),
            "translations": newJArray()
          }))
        except Exception as e:
          displayError("<services.tim> " & e.msg)
          error("error", getCurrentException())
          respond(Http500, render(timInstance, "errors.5xx", layout, data = &*{
            "post": {
              "meta": {
                "title": "Something went wrong",
                "description": "The page you are looking for does not exist."
              },
            },
            "config": globalStupidGreenConfig,
            "currentLang": "",
            "siteLangs": newJArray(),
            "translations": newJArray()
          }))

    template renderView*(view: string, httpCode = Http200, local: JsonNode = nil): untyped =
      ## Renders a Tim view without a layout and sends it as an HTTP response.
      ## This can be used for rendering partials or standalone views.
      block:
        let renderLocal: JsonNode = local
        timRenderLang =
          if not renderLocal.isNil and renderLocal.hasKey("currentLang") and
              renderLocal["currentLang"].kind == JString:
            renderLocal["currentLang"].getStr()
          else: ""
        try:
          let output = renderView(timInstance, view, renderLocal)
          respond(httpCode, output)
        except TimEngineError as e:
          logger("Tim Engine: " & e.msg, ERROR)
          respond(Http500, renderView(timInstance, "errors.5xx", data = &*{
            "post": {
              "meta": {
                "title": "Something went wrong",
                "description": "The page you are looking for does not exist."
              },
            },
            "config": globalStupidGreenConfig,
            "currentLang": "",
            "siteLangs": newJArray(),
            "translations": newJArray()
          }))
        except Exception as e:
          logger("Tim Engine: " & e.msg, ERROR)
          error("error", getCurrentException())
          respond(Http500, renderView(timInstance, "errors.5xx", data = &*{
            "post": {
              "meta": {
                "title": "Something went wrong",
                "description": "The page you are looking for does not exist."
              },
            },
            "config": globalStupidGreenConfig,
            "currentLang": "",
            "siteLangs": newJArray(),
            "translations": newJArray()
          }))
      return # blocks further execution in the route handler after rendering the view
