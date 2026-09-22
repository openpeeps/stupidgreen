# StupidGreen - A static blog generator for cool kids!
#
# (c) 2026 George Lemon | AGPL-3.0-or-later License
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
  themeStub4xx = staticRead(storagePath / "stubs" / "theme" / "views" / "errors" / "4xx.timl")
  themeStub5xx = staticRead(storagePath / "stubs" / "theme" / "views" / "errors" / "5xx.timl")
  themeStubStyle = staticRead(storagePath / "stubs" / "theme" / "assets" / "style.css")

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
  for diskName in ["project-assets", "theme-active", "theme-default"]:
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

proc newCommand*(v: Values) =
  ## Create a new StupidGreen project in the specified directory
  let dirPath = absolutePath($(v.get("project").getStr))
  createDir(dirPath)
  if v.has("--json"):
    writeFile(dirPath / "stupidgreen.config.json", parseYaml(tpl).toJson())
  else:
    writeFile(dirPath / "stupidgreen.config.yaml", tpl)
  createDir(dirPath / "posts")
  createDir(dirPath / "pages")
  createDir(dirPath / "assets")
  writeFile(dirPath / "posts" / "index.md", defaultHomePage)
  writeFile(dirPath / "posts" / "hello-world.md", samplePost)
  writeFile(dirPath / "pages" / "about.md", samplePage)
  writeFile(dirPath / "pages" / "llms.md", sampleLlms)
  seedDefaultTheme(dirPath)
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
  let postsDir = getCurrentDir() / "posts"
  if not dirExists(postsDir):
    displayError("No StupidGreen project found in the current directory. Run `stupidgreen new <directory>` first.", quitProcess = true)
  let fpath = postsDir / (slug & ".md")
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

proc scaffoldTheme*(projectPath, name, author: string): int =
  ## Writes a blank theme skeleton into `<projectPath>/themes/<name>/`.
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
    ("views/errors/4xx.timl", themeStub4xx),
    ("views/errors/5xx.timl", themeStub5xx),
    ("assets/style.css", themeStubStyle),
  ]
  result = 0
  for (rel, content) in themeFiles:
    let dest = projectPath / "themes" / name / rel
    createDir(dest.parentDir)
    var text = content
    if rel == "theme.yaml":
      text = text.replace("__THEME_NAME__", name).replace("__THEME_AUTHOR__", author)
    writeFile(dest, text)
    inc result

proc themeCommand*(v: Values) =
  ## Create a new blank StupidGreen theme in `themes/<name>` of the
  ## current project. Never touches `stupidgreen.config` — activate the
  ## theme by setting `theme: "<name>"` yourself (theme work usually
  ## happens in dev mode).
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
  let projectPath = getCurrentDir()
  if not fileExists(projectPath / "stupidgreen.config.yml") and
     not fileExists(projectPath / "stupidgreen.config.yaml") and
     not fileExists(projectPath / "stupidgreen.config.json"):
    displayError("No StupidGreen project found in the current directory. Run `stupidgreen new <directory>` first.", quitProcess = true)
  let destRoot = projectPath / "themes" / name
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
  let written = scaffoldTheme(projectPath, name, author)
  display("Created a new StupidGreen theme in " & destRoot & " (" & $written & " files)")
  display("Next steps:")
  display("  set `theme: \"" & name & "\"` in stupidgreen.config.yaml to activate it")
  display("  stupidgreen run --sync   # preview with live reload")
  quit(0)

proc runCommand*(v: Values) =
  ## Start the StupidGreen development server
  # compat: supranim 0.1.10 `initStartCommand` still reads the project
  # path from the legacy `directory` key (develop 0.1.11 uses `project`).
  # Mirror it so both supranim generations work; drop when 0.1.11 lands.
  v[]["directory"] = v.get("project")
  initStartCommand(v, createDirs = false)
  let
    projectPath = absolutePath($(v.get("project").getPath))
    port =
      if v.has("--port"): v.get("--port").getPort
      else: 8000.Port

  enableBrowserSync = v.has("--sync")
  # Set the server port in the application configuration
  App.configs["server"].putInt("port", port.int.int64)
  App.configs["tim"].putBool("sync", enableBrowserSync)

  loadStupidGreen(projectPath)
  stupidgreenProjectPath = projectPath
  seedDefaultTheme(projectPath)
  initThemeDisks(projectPath)
  if v.has("--devMode"):
    # theme development: serve theme assets live from source through the
    # storage disks, without copying anything into the public `assets/` dir.
    # Works with symlinked theme dirs (`ln -s <source> themes/<name>`).
    displayWarning("SG Dev-mode enabled: Serving theme assets live from source, no public copy")
  else:
    copyThemeAssetsToPublic(projectPath)

  # init ActivityPub federation (no-op when disabled in the config)
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
  initThemeDisks(projectPath)

  let app = appInstance()
  let installPath = app.applicationPaths.getInstallationPath
  let postsPath = installPath / "posts"
  let pagesPath = installPath / "pages"
  let storePath = installPath / "storage" / "stupidgreen"
  let outputPath = installPath / "_build"

  app.initMarkdownInstance(storePath)
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

  discard existsOrCreateDir(outputPath)
  discard existsOrCreateDir(outputPath / "assets")

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

  let
    perPage = globalStupidGreenConfig.pagination.per_page
    sortedPosts = gMarkdownService.sorted
    totalPages = max(1, (sortedPosts.len + perPage - 1) div perPage)
    intro =
      (if gMarkdownService.pages.hasKey("/"): renderHtml(gMarkdownService.pages["/"])
      elif gMarkdownService.posts.hasKey("/"): renderHtml(gMarkdownService.posts["/"])
      else: "")

  proc indexPageUrl(n: int): string =
    ## Returns the URL of a blog index page
    if n == 1: "/" else: "/page/" & $n

  # blog index + paginated index (homepage renders index.timl with the intro
  # from `pages/index.md`/`posts/index.md` and the list of posts)
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
    local["prevUrl"] = %((if pageNum > 1: indexPageUrl(pageNum - 1) else: ""))
    local["nextUrl"] = %((if pageNum < totalPages: "/page/" & $(pageNum + 1) else: ""))
    local["intro"] = %(intro)
    writeRouteHtml("index", indexPageUrl(pageNum), local)

  # individual posts
  for url, post in gMarkdownService.posts:
    if url == "/" or post.meta.draft:
      continue
    var local = newJObject()
    local["config"] = configJson()
    local["post"] = postJsonRendered(post)
    writeRouteHtml("post", url, local)

  # standalone pages (the homepage at `/` is the blog index, rendered above)
  for url, page in gMarkdownService.pages:
    if page.meta.draft or url == "/":
      continue
    var local = newJObject()
    local["config"] = configJson()
    local["page"] = postJsonRendered(page)
    writeRouteHtml("page", url, local)

  # tag archives
  for tagSlug, tagPosts in gMarkdownService.byTag:
    var local = newJObject()
    local["config"] = configJson()
    local["posts"] = postsJson(tagPosts)
    local["tag"] = %(gMarkdownService.tagNames.getOrDefault(tagSlug, tagSlug))
    local["tagSlug"] = %(tagSlug)
    writeRouteHtml("tag", "/tags/" & tagSlug, local)

  # category archives
  for catSlug, catPosts in gMarkdownService.byCategory:
    var local = newJObject()
    local["config"] = configJson()
    local["posts"] = postsJson(catPosts)
    local["category"] = %(gMarkdownService.categoryNames.getOrDefault(catSlug, catSlug))
    local["categorySlug"] = %(catSlug)
    writeRouteHtml("category", "/categories/" & catSlug, local)

  # search results
  let searchEntries = spotlight().getEntries()
  var resultsArray = newJArray()
  for entry in searchEntries:
    var je = newJObject()
    je["url"] = %(entry.url)
    je["title"] = %(entry.title)
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

  # feed + sitemap
  let allPosts = toSeq(gMarkdownService.posts.values)
  let allPages = toSeq(gMarkdownService.pages.values)
  if globalStupidGreenConfig.feed.enable:
    writeFile(outputPath / "feed.xml", feedXml(allPosts, globalStupidGreenConfig, baseUrl()))
  writeFile(outputPath / "sitemap.xml", sitemapXml(allPosts, allPages, globalStupidGreenConfig, baseUrl()))

  # llms.txt (from the project's pages/llms.md)
  let llms = llmsTxtContent(installPath / "pages")
  if llms.len > 0:
    writeFile(outputPath / "llms.txt", llms)

  display("Build complete: " & outputPath)
  quit(0)
