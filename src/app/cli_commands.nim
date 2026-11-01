# StupidGreen - A static blog generator for cool kids!
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps

import std/[os, osproc, sequtils, strutils, tables, json, times]
from std/net import Port

import pkg/openparser/[json, yaml]
import pkg/supranim
import pkg/supranim/core/[application, paths]
import pkg/kapsis/[runtime, cli]
import pkg/kapsis/interactive/prompts
import pkg/supranim/support/slug

import ./structs
import pkg/supranim/service/storage
import ../service/provider/[markdown, tim, search, feed, activitypub, assets]

const
  tpl = staticRead(storagePath / "stubs" / "template_stupidgreen.config.yaml")
    # a static template for the default StupidGreen config file, used when creating new projects
  defaultHomePage = staticRead(storagePath / "stubs" / "index.md")
    # the default homepage intro used when scaffolding a new project
  samplePost = staticRead(storagePath / "stubs" / "hello-world.md")
    # a sample post written when scaffolding a new project
  samplePage = staticRead(storagePath / "stubs" / "about.md")
    # a sample page written when scaffolding a new project
  sampleLlms = staticRead(storagePath / "stubs" / "llms.md")
    # a sample `llms.md` written when scaffolding a new project
  themeStubThemeYaml = staticRead(storagePath / "stubs" / "theme" / "theme.yaml")
    # manifest template for `stupidgreen theme` (`__THEME_NAME__`/`__THEME_AUTHOR__` replaced at write time)
  themeStubBase = staticRead(storagePath / "stubs" / "theme" / "layouts" / "base.timl")
  themeStubHeader = staticRead(storagePath / "stubs" / "theme" / "partials" / "header.timl")
  themeStubPostCards = staticRead(storagePath / "stubs" / "theme" / "partials" / "post-cards.timl")
  themeStubPagination = staticRead(storagePath / "stubs" / "theme" / "partials" / "pagination.timl")
  themeStubIndex = staticRead(storagePath / "stubs" / "theme" / "views" / "index.timl")
  themeStubPage = staticRead(storagePath / "stubs" / "theme" / "views" / "page.timl")
  themeStubPost = staticRead(storagePath / "stubs" / "theme" / "views" / "post.timl")
  themeStubTag = staticRead(storagePath / "stubs" / "theme" / "views" / "tag.timl")
  themeStubCategory = staticRead(storagePath / "stubs" / "theme" / "views" / "category.timl")
  themeStubSearch = staticRead(storagePath / "stubs" / "theme" / "views" / "search.timl")
  themeStubLanding = staticRead(storagePath / "stubs" / "theme" / "views" / "landing.timl")
  themeStub4xx = staticRead(storagePath / "stubs" / "theme" / "views" / "errors" / "4xx.timl")
  themeStub5xx = staticRead(storagePath / "stubs" / "theme" / "views" / "errors" / "5xx.timl")
  themeStubStyle = staticRead(storagePath / "stubs" / "theme" / "assets" / "style.css")
  themeStubSweetSyntaxCss = staticRead(storagePath / "stubs" / "theme" / "assets" / "sweetsyntax.css")
  themeStubSyntaxReadme = staticRead(storagePath / "stubs" / "theme" / "syntax" / "README.md")
  enPotTemplate = staticRead(storagePath / "en.pot")
    # English gettext message template, written to `<project>/storage/en.pot`.
    # Translators copy it to `<lang>.po` next to it and fill in `msgstr`.

proc loadStupidGreen(projectPath: string) =
  ## Loads the StupidGreen configuration from the project directory
  let configPath = projectPath / "stupidgreen.config"
  if fileExists(configPath & ".yml"):
    globalStupidGreenConfig = parseYAML(readFile(configPath & ".yml"), StupidGreenConfig)
  elif fileExists(configPath & ".yaml"):
    globalStupidGreenConfig = parseYAML(readFile(configPath & ".yaml"), StupidGreenConfig)
  elif fileExists(configPath & ".json"):
    globalStupidGreenConfig = fromJson(readFile(configPath & ".json"), StupidGreenConfig)
  else:
    display("No StupidGreen Config found in the current directory (.yml/.yaml/.json)")
    QuitFailure.quit
  globalStupidGreenConfig.ensureLeadingSlash()
  # `metadata.url` is required: it feeds absolute asset/feed/sitemap links
  # (exposed to templates as `site.baseUrl`). Bare domains, subdomains and
  # subpaths are accepted (`website.com`, `sub.website.com`,
  # `website.com/other/website`); the scheme defaults to https.
  globalStupidGreenConfig.metadata.url = normalizeSiteUrl(globalStupidGreenConfig.metadata.url)
  if globalStupidGreenConfig.metadata.url.len == 0:
    displayError("`metadata.url` is missing in stupidgreen.config.yaml. Set it to your " &
      "web address, e.g. `url: \"website.com\"` (subpaths work too: `website.com/docs`).",
      quitProcess = true)
  # `parseYAML` leaves absent keys at their zero value (Nim field
  # defaults do not survive parsing), so projects predating the
  # `server` section are normalized to the built-in defaults here.
  # (`threads: 0` passes through: powpow reads it as one worker per core.)
  if globalStupidGreenConfig.server.port == 0:
    globalStupidGreenConfig.server.port = 8000
  if globalStupidGreenConfig.server.address.len == 0:
    globalStupidGreenConfig.server.address = "127.0.0.1"

const defaultThemeName* = "default"
  ## Name of the built-in fallback theme shipped with StupidGreen

proc activeThemeName*(): string =
  ## The theme selected in `stupidgreen.config`, defaulting to
  ## the built-in theme when unset (e.g. configs predating themes).
  let t = globalStupidGreenConfig.theme.strip()
  if t.len > 0: t else: defaultThemeName

proc seedDefaultTheme*(projectPath: string) =
  ## Ensures `<project>/themes/default/` contains every file shipped with
  ## the built-in default theme. Only missing files are written, so user
  ## customizations are never overwritten. This also upgrades projects
  ## created before theme support existed. A symlinked theme dir is never
  ## written through — it is left for its devel source to manage.
  let destRoot = projectPath / "themes" / defaultThemeName
  var seeded = 0
  template seedFile(rel, content: string) =
    let dest = destRoot / rel
    if not fileExists(dest):
      createDir(dest.parentDir)
      writeFile(dest, content)
      inc seeded
  if symlinkExists(destRoot):
    # symlinked theme (devel source via `ln -s`): never write through
    # the link, its source tree manages the files
    display("Theme \"" & defaultThemeName & "\" is symlinked, skipping seed")
    return
  when defined release:
    # seed from the default theme bundle embedded in the binary.
    # Text files come from the "default" directory table, binary files
    # (images, fonts) from the raw asset store.
    const prefix = "/default/"
    let sta = staticAssets()
    for key in sta.listAssetsDir("/default"):
      if not key.startsWith(prefix):
        continue
      var content: string
      if sta.hasAsset(key):
        content = cast[string](sta.get(key))
      else:
        content = sta.directory("default")[key]
      seedFile(key[prefix.len .. ^1], content)
  else:
    let srcRoot = supranim.basePath / "themes" / defaultThemeName
    if not dirExists(srcRoot):
      displayError("Default theme not found in StupidGreen sources: " & srcRoot, quitProcess = true)
    for srcPath in walkDirRec(srcRoot,
                              yieldFilter = {pcFile, pcLinkToFile},
                              followFilter = {pcDir, pcLinkToDir}):
      if not fileExists(srcPath):
        continue
      let rel = relativePath(srcPath, srcRoot)
      if extractFilename(rel).startsWith("."):
        continue
      seedFile(rel, readFile(srcPath))
  if seeded > 0:
    display("Seeded " & $seeded & " default theme file(s) into themes/" & defaultThemeName & "/")

proc initThemeDisks*(projectPath: string) =
  ## Registers runtime storage disks for public assets:
  ## `project-assets` (read/write), `theme-active` and `theme-default`
  ## (read-only). Used to serve `/assets/*` with project-first precedence.
  storage.init(App)
  storage().addDisk("project-assets",
    newLocalDriver(projectPath / "assets"))
  let active = activeThemeName()
  storage().addDisk("theme-active",
    newLocalDriver(projectPath / "themes" / active / "assets"),
    PolicyRules(readOnly: true))
  storage().addDisk("theme-default",
    newLocalDriver(projectPath / "themes" / defaultThemeName / "assets"),
    PolicyRules(readOnly: true))

proc resolvePublicAsset*(rel: string): string =
  ## Resolves a public `/assets/...` path to an absolute file path,
  ## probing project assets first, then the active theme, then the
  ## default (fallback) theme. Returns "" when no disk provides it.
  let relPath = normalizedPath(rel.strip(chars = {'/'}, leading = true))
  if relPath.len == 0 or relPath.startsWith(".") or relPath == ".." or
     relPath.startsWith(".." / ""):
    return ""
  # In devMode the active theme's `assets/` is served live (first), so
  # edits to `themes/<name>/assets/` are visible without a restart or a
  # copy step. Project assets remain reachable as a fallback.
  let diskOrder =
    if enableDevMode: @["theme-active", "theme-default", "project-assets"]
    else: @["project-assets", "theme-active", "theme-default"]
  for diskName in diskOrder:
    try:
      let d = storage().rawDisk(diskName)
      if d.exists(relPath):
        let full = d.root / relPath
        if fileExists(full):
          return full
    except StorageError:
      continue
  return ""

proc copyThemeAssetsToPublic*(projectPath: string) =
  ## Copies fallback + active theme assets into `<project>/assets/`, the
  ## directory used for public serving. Same-named files are always
  ## overwritten so the served files match the active theme — customize
  ## `themes/<name>/assets/style.css` itself, not the public copy.
  ## Files the theme doesn't ship are left alone.
  let destRoot = projectPath / "assets"
  createDir(destRoot)
  var copied = 0
  proc copyThemeDir(themeName: string) =
    let assetsDir = projectPath / "themes" / themeName / "assets"
    if not dirExists(assetsDir):
      return
    # follow symlinks so symlinked theme trees (theme dev via `ln -s`)
    # copy exactly like regular directories
    for fpath in walkDirRec(assetsDir,
                            yieldFilter = {pcFile, pcLinkToFile},
                            followFilter = {pcDir, pcLinkToDir}):
      if not fileExists(fpath):
        continue
      let rel = relativePath(fpath, assetsDir)
      if extractFilename(rel).startsWith("."):
        continue
      let dest = destRoot / rel
      try:
        createDir(dest.parentDir)
        copyFile(fpath, dest)
        inc copied
      except:
        display("Could not copy theme asset: " & rel)
  copyThemeDir(defaultThemeName)
  if activeThemeName() != defaultThemeName:
    copyThemeDir(activeThemeName())
  if copied > 0:
    display("Public assets synced from theme \"" & activeThemeName() &
      "\" (" & $copied & " file(s) into assets/)")

proc seedStorageLocale*(projectPath: string) =
  ## Ensures `<project>/storage/en.pot` exists (the English gettext
  ## message template translators copy to `<lang>.po`). Only writes
  ## when missing, so translator files and template edits are kept.
  let dest = projectPath / "storage" / "en.pot"
  if not fileExists(dest):
    createDir(dest.parentDir)
    writeFile(dest, enPotTemplate)

proc newCommand*(v: Values) =
  ## Create a new StupidGreen project in the specified directory.
  ## With `--pages` the project is a pages-only site: no `posts/`
  ## directory and `mode: "pages"` in the config, so the blogging
  ## system (posts, tags, categories, feed) stays disabled.
  let
    dirPath = absolutePath($(v.get("project").getStr))
    pagesMode = v.has("--pages")
  var configText = tpl
  if pagesMode:
    configText = configText.replace("mode: \"blog\"", "mode: \"pages\"")
  createDir(dirPath)
  if v.has("--json"):
    writeFile(dirPath / "stupidgreen.config.json", parseYaml(configText).toJson())
  else:
    writeFile(dirPath / "stupidgreen.config.yaml", configText)
  createDir(dirPath / "pages")
  createDir(dirPath / "assets")
  if pagesMode:
    writeFile(dirPath / "pages" / "index.md", defaultHomePage)
  else:
    createDir(dirPath / "posts")
    writeFile(dirPath / "posts" / "index.md", defaultHomePage)
    writeFile(dirPath / "posts" / "hello-world.md", samplePost)
  writeFile(dirPath / "pages" / "about.md", samplePage)
  writeFile(dirPath / "pages" / "llms.md", sampleLlms)
  seedDefaultTheme(dirPath)
  seedStorageLocale(dirPath)
  display("Created a new StupidGreen project in " & dirPath)
  display("Next steps:")
  display("  cd " & dirPath)
  display("  stupidgreen run --sync   # start the development server with live reload")
  quit(0)

proc postCommand*(v: Values) =
  ## Create a new blog post in the current project
  let title = $(v.get("title").getStr)
  let slug = title.slugify()
  let today = now().format("yyyy-MM-dd")
  var langSuffix = ""
  if v.has("--lang"):
    let code = ($(v.get("--lang").getStr)).strip().toLowerAscii()
    var valid = code.len in 2..8
    if valid:
      for c in code:
        if c notin {'a'..'z', '0'..'9', '-'}:
          valid = false
          break
    if not valid:
      displayError("Invalid language code \"" & code &
        "\": use 2-8 lowercase letters, digits or dashes (e.g. `ro`).",
        quitProcess = true)
    langSuffix = "." & code
  # in pages mode blog posts are disabled — check the project config
  # before the `posts/` directory, which pages-only projects don't have
  let configPath = getCurrentDir() / "stupidgreen.config"
  if fileExists(configPath & ".yml") or fileExists(configPath & ".yaml") or
      fileExists(configPath & ".json"):
    loadStupidGreen(getCurrentDir())
    if globalStupidGreenConfig.mode == modePages:
      displayError("This project uses pages mode: blog posts are disabled.",
        quitProcess = true)
    if langSuffix.len > 0 and not globalStupidGreenConfig.languagesEnabled():
      displayWarning("The `languages` feature is disabled: `" & slug &
        langSuffix & ".md` will be treated as a regular post until enabled.")
  let postsDir = getCurrentDir() / "posts"
  if not dirExists(postsDir):
    displayError("No StupidGreen project found in the current directory. Run `stupidgreen new <directory>` first.", quitProcess = true)
  let fpath = postsDir / (slug & langSuffix & ".md")
  if fileExists(fpath):
    displayError("A post with this title already exists: " & fpath, quitProcess = true)
  let postContent =
    "---\n" &
    "title: \"" & title & "\"\n" &
    "date: \"" & today & "\"\n" &
    "tags: []\n" &
    "categories: []\n" &
    "draft: false\n" &
    "---\n\n"
  writeFile(fpath, postContent)
  display("Created post: " & fpath)
  quit(0)

proc scaffoldTheme*(destRoot, name, author: string): int =
  ## Writes a blank theme skeleton into `destRoot` (i.e. `./<name>/`).
  ## Returns the number of files written. The caller must ensure the
  ## destination does not exist yet.
  let themeFiles = [
    ("theme.yaml", themeStubThemeYaml),
    ("layouts/base.timl", themeStubBase),
    ("partials/header.timl", themeStubHeader),
    ("partials/post-cards.timl", themeStubPostCards),
    ("partials/pagination.timl", themeStubPagination),
    ("views/index.timl", themeStubIndex),
    ("views/page.timl", themeStubPage),
    ("views/post.timl", themeStubPost),
    ("views/tag.timl", themeStubTag),
    ("views/category.timl", themeStubCategory),
    ("views/search.timl", themeStubSearch),
    ("views/landing.timl", themeStubLanding),
    ("views/errors/4xx.timl", themeStub4xx),
    ("views/errors/5xx.timl", themeStub5xx),
    ("assets/style.css", themeStubStyle),
    ("assets/sweetsyntax.css", themeStubSweetSyntaxCss),
    ("syntax/README.md", themeStubSyntaxReadme),
  ]
  result = 0
  for (rel, content) in themeFiles:
    let dest = destRoot / rel
    createDir(dest.parentDir)
    var text = content
    if rel == "theme.yaml":
      text = text.replace("__THEME_NAME__", name).replace("__THEME_AUTHOR__", author)
    writeFile(dest, text)
    inc result

proc themeCommand*(v: Values) =
  ## Create a new blank StupidGreen theme in `./<name>`. Works anywhere —
  ## no project required. Copy or symlink the result into a project's
  ## `themes/` dir and set `theme: "<name>"` to use it.
  let name = $(v.get("name").getStr)
  if name.len == 0:
    displayError("Theme name cannot be empty.", quitProcess = true)
  for c in name:
    if c notin {'a'..'z', '0'..'9', '-', '_'}:
      displayError("Invalid theme name \"" & name &
        "\". Use lowercase letters, digits, dashes and underscores.", quitProcess = true)
  if name == defaultThemeName:
    displayError("Cannot create a theme named \"" & name &
      "\" — it is the built-in fallback theme.", quitProcess = true)
  let destRoot = getCurrentDir() / name
  if fileExists(destRoot) or dirExists(destRoot) or symlinkExists(destRoot):
    displayError("A theme already exists: " & destRoot, quitProcess = true)
  var author = ""
  try:
    # prefer the git user name for the theme manifest author
    let (gitName, gitCode) = execCmdEx("git config user.name")
    if gitCode == 0 and gitName.strip().len > 0:
      author = gitName.strip().replace("\"", "")
  except OSError:
    discard
  let written = scaffoldTheme(destRoot, name, author)
  display("Created a new StupidGreen theme in " & destRoot & " (" & $written & " files)")
  display("Next steps:")
  display("  copy it to <project>/themes/" & name & " (or symlink it for live development)")
  display("  set `theme: \"" & name & "\"` in stupidgreen.config.yaml to activate it")
  quit(0)

proc runCommand*(v: Values) =
  ## Start the StupidGreen development server
  # compat: supranim 0.1.10 `initStartCommand` still reads the project
  # path from the legacy `directory` key (develop 0.1.11 uses `project`).
  # Mirror it so both supranim generations work; drop when 0.1.11 lands.
  v[]["directory"] = v.get("project")
  initStartCommand(v, createDirs = false)
  let projectPath = absolutePath($(v.get("project").getPath))
  loadStupidGreen(projectPath)
  let
    sgServer = globalStupidGreenConfig.server
    port =
      if v.has("--port"): v.get("--port").getPort
      else:
        if sgServer.port notin 1 .. 65535:
          displayError("Invalid `server.port` in stupidgreen.config.yaml: \"" &
            $sgServer.port & "\" (expected 1..65535)", quitProcess = true)
          quit(1)
        Port(sgServer.port)

  enableBrowserSync = v.has("--sync")
  enableDevMode = v.has("--devMode")
  # Hand the project server settings to the framework (`putInt` only
  # addresses top-level keys, so the nested `server` table is updated
  # directly). `--port` wins over the file; the rest always comes from
  # the project config, falling back to built-in defaults for projects
  # predating the `server` section.
  let srvTable = App.configs["app"].tomlDoc.tableVal["server"]
  srvTable.tableVal["address"] = newTomlString(sgServer.address)
  srvTable.tableVal["port"] = newTomlInteger(port.int.int64)
  srvTable.tableVal["threads"] = newTomlInteger(sgServer.threads.int64)
  srvTable.tableVal["unix"] = newTomlBoolean(sgServer.unix)
  App.configs["tim"].putBool("sync", enableBrowserSync)

  stupidgreenProjectPath = projectPath
  seedDefaultTheme(projectPath)
  seedStorageLocale(projectPath)
  tim.loadI18n(projectPath)
  initThemeDisks(projectPath)
  if v.has("--devMode"):
    # theme development: serve theme assets live from `themes/<name>/assets/`
    # through the storage disks (see `resolvePublicAsset`), without copying
    # anything into the public `assets/` dir, so edits are visible on refresh.
    # Works with symlinked theme dirs (`ln -s <source> themes/<name>`).
    displayWarning("SG Dev-mode enabled: Serving theme assets live from source, no public copy")
  else:
    copyThemeAssetsToPublic(projectPath)

  # init ActivityPub federation (no-op when disabled in the config).
  # In pages mode federation is skipped entirely: it is part of the
  # blogging system.
  if globalStupidGreenConfig.mode != modePages:
    var base = globalStupidGreenConfig.metadata.url
    while base.len > 0 and base[^1] == '/':
      base.setLen(base.len - 1)
    activitypub.initActivityPub(projectPath, base, globalStupidGreenConfig.activitypub)

proc buildCommand*(v: Values) =
  ## Build the blog for production - generates static HTML website
  # compat: see `runCommand` — mirror `project` as legacy `directory`
  v[]["directory"] = v.get("project")
  initStartCommand(v, createDirs = false)
  let
    projectPath = absolutePath($(v.get("project").getPath))

  loadStupidGreen(projectPath)
  stupidgreenProjectPath = projectPath
  seedDefaultTheme(projectPath)
  seedStorageLocale(projectPath)
  tim.loadI18n(projectPath)
  initThemeDisks(projectPath)

  let app = appInstance()
  let installPath = app.applicationPaths.getInstallationPath
  let postsPath = installPath / "posts"
  let pagesPath = installPath / "pages"
  let dbFile = installPath / "storage" / "stupidgreen.db"
  let outputPath =
    if v.has("--out"):
      # custom output dir (created with parents when missing);
      # replaces the default `<project>/_build`
      absolutePath($(v.get("--out").getStr))
    else:
      installPath / "_build"

  app.initMarkdownInstance(dbFile)
  scanMarkdownFiles(postsPath, pagesPath)

  tim.buildSetup(
    src = App.config("tim.source").getStr,
    output = App.config("tim.output").getStr,
    basePath = projectPath,
    global = %*{
      "isDev": false,
      "enableMarkdownSync": false,
      "browserSync": {},
    },
    activeTheme = activeThemeName(),
    fallbackTheme = defaultThemeName
  )

  createDir(outputPath)
  createDir(outputPath / "assets")

  proc copyDiskAssets(diskName: string) =
    ## Copies every file from a theme/project storage disk into the build
    ## output. Called fallback-first (then active theme, then project), so
    ## later copies overwrite earlier ones and project assets always win.
    var d: StorageDriver
    try:
      d = storage().rawDisk(diskName)
    except StorageError:
      return
    var entries: seq[FileMetadata]
    try:
      entries = d.list("", recursive = true)
    except StorageError:
      return
    for e in entries:
      if e.isDir or extractFilename(e.path).startsWith("."):
        continue
      let dest = outputPath / "assets" / e.path
      try:
        createDir(dest.parentDir)
        writeFile(dest, d.read(e.path))
      except:
        display("Could not copy asset: " & e.path)

  copyDiskAssets("theme-default")
  if activeThemeName() != defaultThemeName:
    copyDiskAssets("theme-active")
  copyDiskAssets("project-assets")

  proc configJson(): JsonNode =
    ## Converts the global StupidGreen configuration to a JsonNode
    fromJson(toJson(globalStupidGreenConfig))

  proc postsJson(posts: seq[Post]): JsonNode =
    ## Converts a sequence of posts to a JsonNode array
    fromJson(toJson(posts))

  proc postJson(post: Post): JsonNode =
    ## Converts a single post to a JsonNode
    fromJson(toJson(post))

  proc postJsonRendered(post: Post): JsonNode =
    ## Converts a single post to a JsonNode, rendering its Markdown
    ## source into HTML (used by templates)
    result = postJson(post)
    result["content"] = %(renderHtml(post))
    result["content_markdown"] = %resolvePostRefs(post.content)

  proc writeRouteHtml(view, routePath: string; local: JsonNode) =
    ## Renders a route using Tim and writes it to the output directory
    let html = tim.buildRender(view, routePath, local)
    if routePath == "/":
      writeFile(outputPath / "index.html", html)
    else:
      let cleanPath = routePath.strip(chars = {'/'}, leading = true)
      let pageDir = outputPath / cleanPath
      createDir(pageDir)
      writeFile(pageDir / "index.html", html)

  proc baseUrl(): string =
    ## Returns the configured base URL without a trailing slash
    result = globalStupidGreenConfig.metadata.url
    while result.len > 0 and result[^1] == '/':
      result.setLen(result.len - 1)

  let pagesMode = globalStupidGreenConfig.mode == modePages

  proc pageView(post: Post, defaultView: string): string =
    ## Resolves the Tim view for a post/page from its front-matter
    ## `layout`, warning and falling back to `defaultView` when the
    ## theme provides no matching template
    if post.meta.layout.strip().len == 0:
      return defaultView
    result = tim.resolvePageView(post.meta.layout, defaultView)
    if result == defaultView:
      displayWarning("Unknown layout \"" & post.meta.layout &
        "\" for " & post.meta.url & ", using \"" & defaultView & "\"")

  proc extraLangs(): seq[string] =
    ## Non-default supported languages (empty when the feature is disabled).
    if not globalStupidGreenConfig.languagesEnabled():
      return @[]
    let defLang = globalStupidGreenConfig.defaultLangCode()
    for l in globalStupidGreenConfig.supportedLangCodes():
      if l != defLang and l notin result:
        result.add(l)

  proc buildIntro(lang: string): string =
    ## Homepage intro for `lang` (translated intro with fallback
    ## to the default intro, mirroring the dev server).
    if lang.len > 0:
      let lurl = "/" & lang
      if gMarkdownService.pages.hasKey(lurl):
        return renderHtml(gMarkdownService.pages[lurl])
      if gMarkdownService.posts.hasKey(lurl):
        return renderHtml(gMarkdownService.posts[lurl])
    if gMarkdownService.pages.hasKey("/"):
      return renderHtml(gMarkdownService.pages["/"])
    elif gMarkdownService.posts.hasKey("/"):
      return renderHtml(gMarkdownService.posts["/"])
    ""

  if pagesMode:
    # pages-only site: `/` renders `pages/index.md` through its layout
    # view, every other page through its own layout view. The blogging
    # system (index pagination, posts, tags, categories, feed) is
    # disabled entirely.
    if not gMarkdownService.pages.hasKey("/"):
      displayError("Pages mode requires a homepage: create `pages/index.md`.",
        quitProcess = true)
    let home = gMarkdownService.pages["/"]
    if home.meta.draft:
      displayError("Pages mode requires a homepage: `pages/index.md` is a draft.",
        quitProcess = true)
    var homeLocal = newJObject()
    homeLocal["config"] = configJson()
    homeLocal["page"] = postJsonRendered(home)
    homeLocal["currentLang"] = %(pubLang(home.meta.lang))
    homeLocal["siteLangs"] = %(pubLangs())
    homeLocal["translations"] = translationsArray(home.meta.translations)
    writeRouteHtml(pageView(home, "page"), "/", homeLocal)
    # translated homepages (`/<lang>`, 404 when missing at serve time)
    for lang in extraLangs():
      let lurl = "/" & lang
      if gMarkdownService.pages.hasKey(lurl) and
          not gMarkdownService.pages[lurl].meta.draft:
        let lhome = gMarkdownService.pages[lurl]
        var lhomeLocal = newJObject()
        lhomeLocal["config"] = configJson()
        lhomeLocal["page"] = postJsonRendered(lhome)
        lhomeLocal["currentLang"] = %(pubLang(lang))
        lhomeLocal["siteLangs"] = %(pubLangs())
        lhomeLocal["translations"] = translationsArray(lhome.meta.translations)
        writeRouteHtml(pageView(lhome, "page"), lurl, lhomeLocal)

    for url, page in gMarkdownService.pages:
      if page.meta.draft or url == "/":
        continue
      var local = newJObject()
      local["config"] = configJson()
      local["page"] = postJsonRendered(page)
      local["currentLang"] = %(pubLang(page.meta.lang))
      local["siteLangs"] = %(pubLangs())
      local["translations"] = translationsArray(page.meta.translations)
      writeRouteHtml(pageView(page, "page"), url, local)
  else:
    let perPage = globalStupidGreenConfig.pagination.per_page

    # blog index + paginated index per language (homepage renders
    # index.timl with the intro and the list of posts for that lang)
    for lang in @[""] & extraLangs():
      let
        sortedPosts =
          if lang.len == 0: gMarkdownService.sorted
          else: gMarkdownService.sortedByLang.getOrDefault(lang, @[])
        totalPages = max(1, (sortedPosts.len + perPage - 1) div perPage)
        intro = buildIntro(lang)

      proc indexPageUrl(lang: string; n: int): string =
        ## Returns the URL of a blog index page (language-prefixed)
        prefixUrl(lang, if n == 1: "/" else: "/page/" & $n)

      for pageNum in 1 .. totalPages:
        var pagePosts: seq[Post] = @[]
        let startIdx = (pageNum - 1) * perPage
        for i in startIdx ..< min(startIdx + perPage, sortedPosts.len):
          pagePosts.add(sortedPosts[i])
        var local = newJObject()
        local["config"] = configJson()
        local["posts"] = postsJson(pagePosts)
        local["page"] = %(pageNum)
        local["totalPages"] = %(totalPages)
        local["prevUrl"] = %((if pageNum > 1: indexPageUrl(lang, pageNum - 1) else: ""))
        local["nextUrl"] = %((if pageNum < totalPages: indexPageUrl(lang, pageNum + 1) else: ""))
        local["intro"] = %(intro)
        local["currentLang"] = %(pubLang(lang))
        local["siteLangs"] = %(pubLangs())
        local["translations"] = siteTranslations(
          proc(l: string): string = indexPageUrl(l, pageNum))
        writeRouteHtml("index", indexPageUrl(lang, pageNum), local)

    # individual posts (each translation carries its own prefixed URL)
    for url, post in gMarkdownService.posts:
      if post.meta.draft or post.meta.slug == "/":
        continue
      var local = newJObject()
      local["config"] = configJson()
      local["post"] = postJsonRendered(post)
      local["currentLang"] = %(pubLang(post.meta.lang))
      local["siteLangs"] = %(pubLangs())
      local["translations"] = translationsArray(post.meta.translations)
      writeRouteHtml(pageView(post, "post"), url, local)

    # standalone pages (the homepage at `/` is the blog index, rendered above)
    for url, page in gMarkdownService.pages:
      if page.meta.draft or url == "/":
        continue
      var local = newJObject()
      local["config"] = configJson()
      local["page"] = postJsonRendered(page)
      local["currentLang"] = %(pubLang(page.meta.lang))
      local["siteLangs"] = %(pubLangs())
      local["translations"] = translationsArray(page.meta.translations)
      writeRouteHtml(pageView(page, "page"), url, local)

    # tag archives (default + per-language)
    for tagSlug, tagPosts in gMarkdownService.byTag:
      var local = newJObject()
      local["config"] = configJson()
      local["posts"] = postsJson(tagPosts)
      local["tag"] = %(gMarkdownService.tagNames.getOrDefault(tagSlug, tagSlug))
      local["tagSlug"] = %(tagSlug)
      local["currentLang"] = %(pubLang(""))
      local["siteLangs"] = %(pubLangs())
      local["translations"] = siteTranslations(
        proc(l: string): string = prefixUrl(l, "/tags/" & tagSlug))
      writeRouteHtml("tag", "/tags/" & tagSlug, local)
    for lang in extraLangs():
      for tagSlug, tagPosts in gMarkdownService.byTagByLang.getOrDefault(
          lang, newTable[string, seq[Post]]()):
        var local = newJObject()
        local["config"] = configJson()
        local["posts"] = postsJson(tagPosts)
        local["tag"] = %(gMarkdownService.tagNamesByLang.getOrDefault(
          lang, newTable[string, string]()).getOrDefault(tagSlug, tagSlug))
        local["tagSlug"] = %(tagSlug)
        local["currentLang"] = %(pubLang(lang))
        local["siteLangs"] = %(pubLangs())
        local["translations"] = siteTranslations(
          proc(l: string): string = prefixUrl(l, "/tags/" & tagSlug))
        writeRouteHtml("tag", "/" & lang & "/tags/" & tagSlug, local)

    # category archives (default + per-language)
    for catSlug, catPosts in gMarkdownService.byCategory:
      var local = newJObject()
      local["config"] = configJson()
      local["posts"] = postsJson(catPosts)
      local["category"] = %(gMarkdownService.categoryNames.getOrDefault(catSlug, catSlug))
      local["categorySlug"] = %(catSlug)
      local["currentLang"] = %(pubLang(""))
      local["siteLangs"] = %(pubLangs())
      local["translations"] = siteTranslations(
        proc(l: string): string = prefixUrl(l, "/categories/" & catSlug))
      writeRouteHtml("category", "/categories/" & catSlug, local)
    for lang in extraLangs():
      for catSlug, catPosts in gMarkdownService.byCategoryByLang.getOrDefault(
          lang, newTable[string, seq[Post]]()):
        var local = newJObject()
        local["config"] = configJson()
        local["posts"] = postsJson(catPosts)
        local["category"] = %(gMarkdownService.categoryNamesByLang.getOrDefault(
          lang, newTable[string, string]()).getOrDefault(catSlug, catSlug))
        local["categorySlug"] = %(catSlug)
        local["currentLang"] = %(pubLang(lang))
        local["siteLangs"] = %(pubLangs())
        local["translations"] = siteTranslations(
          proc(l: string): string = prefixUrl(l, "/categories/" & catSlug))
        writeRouteHtml("category", "/" & lang & "/categories/" & catSlug, local)

  # search results
  let searchEntries = spotlight().getEntries()
  var resultsArray = newJArray()
  for entry in searchEntries:
    var je = newJObject()
    je["url"] = %(entry.url)
    je["title"] = %(entry.title)
    je["lang"] = %(entry.lang)
    if entry.description.isSome:
      je["description"] = %(entry.description.get)
    if entry.headings.isSome:
      var headings = newJArray()
      for h in entry.headings.get:
        headings.add(%(h))
      je["headings"] = headings
    resultsArray.add(je)
  var results = newJObject()
  results["results"] = resultsArray
  writeFile(outputPath / "results.json", $results)

  # feed + sitemap (no feed in pages mode: the blogging system is disabled).
  # Feeds stay on their own language: the default feed excludes translations.
  let allPosts = toSeq(gMarkdownService.posts.values)
  let allPages = toSeq(gMarkdownService.pages.values)
  let defLang = globalStupidGreenConfig.defaultLangCode()
  if pagesMode:
    writeFile(outputPath / "sitemap.xml",
      sitemapXml(newSeq[Post](), allPages, globalStupidGreenConfig, baseUrl()))
  else:
    if globalStupidGreenConfig.feed.enable:
      writeFile(outputPath / "feed.xml", feedXml(allPosts.filterIt(
        it.meta.lang.len == 0 or it.meta.lang == defLang),
        globalStupidGreenConfig, baseUrl()))
      for lang in extraLangs():
        writeFile(outputPath / lang / "feed.xml", feedXml(allPosts.filterIt(
          it.meta.lang == lang), globalStupidGreenConfig, baseUrl()))
    writeFile(outputPath / "sitemap.xml", sitemapXml(allPosts, allPages, globalStupidGreenConfig, baseUrl()))

  # llms.txt (from the project's pages/llms.md, plus per-language
  # translations when they exist)
  let llms = llmsTxtContent(installPath / "pages")
  if llms.len > 0:
    writeFile(outputPath / "llms.txt", llms)
  for lang in extraLangs():
    let lcontent = llmsTxtContent(installPath / "pages", lang)
    if lcontent.len > 0:
      writeFile(outputPath / lang / "llms.txt", lcontent)

  display("Build complete: " & outputPath)
  quit(0)
