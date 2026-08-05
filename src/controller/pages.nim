# StupidGreen - A static blog generator for cool kids!
#
# (c) 2026 George Lemon | AGPL-3.0-or-later License
#          Made by Humans from OpenPeeps

import std/[json, strutils, sequtils, os]

import pkg/supranim/[controller, core/paths, core/application]

import ../service/provider/[tim, markdown, search, feed]
import ../app/structs

proc paginatePosts(posts: seq[Post]; page, perPage: int): tuple[items: seq[Post], page, totalPages: int] =
  ## Splits a sequence of posts into pages and returns the items for `page`
  let totalPages = max(1, (posts.len + perPage - 1) div perPage)
  let pageIdx = if page < 1: 1 else: (if page > totalPages: totalPages else: page)
  let startIdx = (pageIdx - 1) * perPage
  var items: seq[Post] = @[]
  for i in startIdx ..< min(startIdx + perPage, posts.len):
    items.add(posts[i])
  (items, pageIdx, totalPages)

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

proc configJson(): JsonNode =
  ## Converts the global StupidGreen configuration to a JsonNode
  fromJson(toJson(globalStupidGreenConfig))

proc baseUrl(): string =
  ## Returns the configured base URL without a trailing slash
  result = globalStupidGreenConfig.metadata.url
  while result.len > 0 and result[^1] == '/':
    result.setLen(result.len - 1)

proc homepageIntro(): string =
  ## Returns the rendered homepage intro content: from `pages/index.md`
  ## when present, otherwise from `posts/index.md`
  if gMarkdownService.pages.hasKey("/"):
    result = renderHtml(gMarkdownService.pages["/"])
  elif gMarkdownService.posts.hasKey("/"):
    result = renderHtml(gMarkdownService.posts["/"])

proc pagePath(n: int): string =
  ## Returns the URL of a blog index page
  if n == 1: "/" else: "/page/" & $n

proc paginationUrls(page, totalPages: int): (string, string) =
  ## Computes the previous/next pagination URLs
  let prev = (if page > 1: pagePath(page - 1) else: "")
  let next = (if page < totalPages: "/page/" & $(page + 1) else: "")
  (prev, next)

proc defaultLlmsText(): string =
  ## Returns a helpful default `llms.txt` payload when no `llms.md` exists
  result = "# " & globalStupidGreenConfig.metadata.title.get("StupidGreen") & "\n\n" &
    globalStupidGreenConfig.metadata.description.get("") & "\n\n" &
    "Add an `llms.md` file to your project's `pages/` directory to customize this file.\n"

ctrl getHomepage:
  ## renders the homepage: the blog index (post cards) with an optional
  ## intro from `pages/index.md` (or `posts/index.md`)
  let (posts, page, totalPages) =
    paginatePosts(gMarkdownService.sorted, 1, globalStupidGreenConfig.pagination.per_page)
  let (prevUrl, nextUrl) = paginationUrls(page, totalPages)
  render("index", local = &*{
    "posts": postsJson(posts),
    "page": page,
    "totalPages": totalPages,
    "prevUrl": prevUrl,
    "nextUrl": nextUrl,
    "intro": homepageIntro(),
    "config": configJson()
  })

ctrl getPagePage:
  ## renders a paginated index page
  let pageNum = req.params["page"].parseInt
  let (posts, page, totalPages) =
    paginatePosts(gMarkdownService.sorted, pageNum, globalStupidGreenConfig.pagination.per_page)
  let (prevUrl, nextUrl) = paginationUrls(page, totalPages)
  render("index", local = &*{
    "posts": postsJson(posts),
    "page": page,
    "totalPages": totalPages,
    "prevUrl": prevUrl,
    "nextUrl": nextUrl,
    "intro": homepageIntro(),
    "config": configJson()
  })

ctrl getPostsSlug:
  ## renders a single post
  let url = "/posts/" & req.params["slug"]
  if gMarkdownService.posts.hasKey(url):
    render("post", local = &*{
      "post": postJsonRendered(gMarkdownService.posts[url]),
      "config": configJson()
    })
  else:
    render("errors.4xx", local = &*{
      "post": {
        "meta": {
          "title": "Page Not Found",
          "description": "The page you are looking for does not exist."
        },
      },
      "config": configJson()
    }, httpCode = Http404)

ctrl getTagsTag:
  ## renders a tag archive page
  let tagSlug = req.params["tag"]
  let posts = gMarkdownService.byTag.getOrDefault(tagSlug, @[])
  let tagName = gMarkdownService.tagNames.getOrDefault(tagSlug, tagSlug)
  render("tag", local = &*{
    "tag": tagName,
    "tagSlug": tagSlug,
    "posts": postsJson(posts),
    "config": configJson()
  })

ctrl getCategoriesCategory:
  ## renders a category archive page
  let catSlug = req.params["category"]
  let posts = gMarkdownService.byCategory.getOrDefault(catSlug, @[])
  let catName = gMarkdownService.categoryNames.getOrDefault(catSlug, catSlug)
  render("category", local = &*{
    "category": catName,
    "categorySlug": catSlug,
    "posts": postsJson(posts),
    "config": configJson()
  })

ctrl getSearch:
  ## renders the search results page.
  ## The rendering of the search results is done at client side
  ## using JavaScript, which fetches the search results from the
  ## getResultsJson endpoint.
  render("search", local = &*{
    "config": configJson()
  })

ctrl getResultsJson:
  ## returns search results as JSON
  var resultsArray = newJArray()
  for entry in spotlight().getEntries():
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
  json(%*{
    "results": resultsArray
  })

ctrl getFeedXml:
  ## returns the RSS/Atom feed as XML
  let xml = feedXml(
    toSeq(gMarkdownService.posts.values),
    globalStupidGreenConfig,
    baseUrl()
  )
  respond(Http200, xml, "application/xml")

ctrl getSitemapXml:
  ## returns the sitemap as XML
  let xml = sitemapXml(
    toSeq(gMarkdownService.posts.values),
    toSeq(gMarkdownService.pages.values),
    globalStupidGreenConfig,
    baseUrl()
  )
  respond(Http200, xml, "application/xml")

ctrl getLlmsTxt:
  ## returns the project's `pages/llms.md` contents as plain text
  let installPath = appInstance().applicationPaths.getInstallationPath
  let content = llmsTxtContent(installPath / "pages")
  respond(Http200, (if content.len > 0: content else: defaultLlmsText()), "text/plain; charset=utf-8")

ctrl getSlug:
  ## renders standalone pages (from the `pages/` directory) or a 4xx fallback
  let url = "/" & req.params["slug"]
  if gMarkdownService.pages.hasKey(url):
    render("page", local = &*{
      "page": postJsonRendered(gMarkdownService.pages[url]),
      "config": configJson()
    })
  else:
    render("errors.4xx", local = &*{
      "post": {
        "meta": {
          "title": "Page Not Found",
          "description": "The page you are looking for does not exist."
        },
      },
      "config": configJson()
    }, httpCode = Http404)
