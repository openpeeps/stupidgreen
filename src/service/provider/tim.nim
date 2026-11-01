# StupidGreen - A static blog generator for cool kids!
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps

import std/[macros, json, strutils, os,
        httpcore, times, options]

import pkg/supranim/support/slug
import pkg/supranim/core/[services, paths]
import pkg/vancode/interpreter/value
import pkg/[tim, iconim, kapsis/framework]
import pkg/openparser/json

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
      ## Resolves a root-relative path (`/assets/style.css`) against the
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
