# StupidGreen - A static blog generator for cool kids!
#
# (c) 2026 George Lemon | AGPL-3.0-or-later License
#          Made by Humans from OpenPeeps

import std/[os, sequtils, strutils, tables, json, times]
from std/net import Port

import pkg/openparser/[json, yaml]
import pkg/supranim
import pkg/supranim/core/[application, paths]
import pkg/kapsis/[runtime, cli]
import pkg/kapsis/interactive/prompts
import pkg/supranim/support/slug

import ./structs
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

proc newCommand*(v: Values) =
  ## Create a new StupidGreen project in the specified directory
  let dirPath = absolutePath($(v.get("directory").getStr))
  if dirExists(dirPath):
    # checking if the directory is empty
    if walkDir(dirPath).toSeq().len > 0:
      displayError("Directory is not empty.", quitProcess = true)
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

proc startCommand*(v: Values) =
  ## Start the StupidGreen development server
  initStartCommand(v, createDirs = false)
  let
    projectPath = absolutePath($(v.get("directory").getPath))
    port =
      if v.has("--port"): v.get("--port").getPort
      else: 8000.Port

  enableBrowserSync = v.has("--sync")
  # Set the server port in the application configuration
  App.configs["server"].put("port", newYamlInteger(port.int))
  App.configs["tim"].put("sync", newYamlBoolean(enableBrowserSync))

  loadStupidGreen(projectPath)
  stupidgreenProjectPath = projectPath

  # init ActivityPub federation (no-op when disabled in the config)
  var base = globalStupidGreenConfig.metadata.url
  while base.len > 0 and base[^1] == '/':
    base.setLen(base.len - 1)
  activitypub.initActivityPub(projectPath, base, globalStupidGreenConfig.activitypub)

proc buildCommand*(v: Values) =
  ## Build the blog for production - generates static HTML website
  initStartCommand(v, createDirs = false)
  let
    projectPath = absolutePath($(v.get("directory").getPath))

  loadStupidGreen(projectPath)
  stupidgreenProjectPath = projectPath

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
    basePath = supranim.basePath,
    global = %*{
      "isDev": false,
      "enableMarkdownSync": false,
      "browserSync": {},
    }
  )

  discard existsOrCreateDir(outputPath)
  discard existsOrCreateDir(outputPath / "assets")

  when defined release:
    # In release builds, assets are embedded in the binary;
    # write them out to disk so the static site has them
    let sta = staticAssets()
    let assetKeys = sta.listAssetsDir("/assets")
    for key in assetKeys:
      let relPath = key.strip(chars={'/'}, leading=true)
      let dest = outputPath / relPath
      createDir(dest.parentDir)
      if sta.hasAsset(key):
        writeFile(dest, cast[string](sta.get(key)))
      else:
        writeFile(dest, sta.directory("assets")[key])
  else:
    let assetsSrc = supranim.basePath / "storage" / "assets"
    if dirExists(assetsSrc):
      for kind, fpath in walkDir(assetsSrc):
        if kind == pcFile:
          let (_, name, ext) = splitFile(fpath)
          try:
            copyFile(fpath, outputPath / "assets" / name & ext)
          except:
            display("Could not copy asset: " & name & ext)
    else:
      display("No built-in assets found, skipping asset copy")

  let projectAssetsCss = projectPath / "assets" / "style.css"
  if fileExists(projectAssetsCss):
    copyFile(projectAssetsCss, outputPath / "assets" / "style.css")

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
