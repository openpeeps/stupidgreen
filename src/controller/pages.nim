# StupidGreen - A static blog generator for cool kids!
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps

import std/[json, strutils, sequtils, os, httpcore, tables]

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

proc effectiveLang*(raw: string): (string, bool) =
  ## Splits a `{lang}` route param into (lang code, ok). ok is false
  ## when the feature is disabled or the code is not supported —
  ## callers then fall back to default (page) routing.
  let l = raw.strip().toLowerAscii()
  if langEnabled() and l in supportedLangs(): (l, true)
  else: ("", false)

proc viewLang*(lang: string): string =
  ## Language code exposed to templates ("" when monolingual).
  pubLang(lang)

proc postsFor*(lang: string): seq[Post] =
  ## Published posts for `lang` (default language when "").
  if not langEnabled() or lang.len == 0:
    gMarkdownService.sorted
  else:
    gMarkdownService.sortedByLang.getOrDefault(lang, @[])

proc tagsFor*(lang: string): TableRef[string, seq[Post]] =
  ## Tag index for `lang` (default language when "").
  if not langEnabled() or lang.len == 0:
    gMarkdownService.byTag
  else:
    gMarkdownService.byTagByLang.getOrDefault(lang,
      newTable[string, seq[Post]]())

proc categoriesFor*(lang: string): TableRef[string, seq[Post]] =
  ## Category index for `lang` (default language when "").
  if not langEnabled() or lang.len == 0:
    gMarkdownService.byCategory
  else:
    gMarkdownService.byCategoryByLang.getOrDefault(lang,
      newTable[string, seq[Post]]())

proc tagNameFor*(lang, slug: string): string =
  ## Display name for a tag slug in `lang` (falls back to the slug).
  let names =
    if not langEnabled() or lang.len == 0: gMarkdownService.tagNames
    else: gMarkdownService.tagNamesByLang.getOrDefault(lang,
      newTable[string, string]())
  names.getOrDefault(slug, slug)

proc categoryNameFor*(lang, slug: string): string =
  ## Display name for a category slug in `lang` (falls back to the slug).
  let names =
    if not langEnabled() or lang.len == 0: gMarkdownService.categoryNames
    else: gMarkdownService.categoryNamesByLang.getOrDefault(lang,
      newTable[string, string]())
  names.getOrDefault(slug, slug)

proc postJson(post: Post): JsonNode =
  ## Converts a single post to a JsonNode
  fromJson(toJson(post))

proc postJsonRendered(post: Post): JsonNode =
  ## Converts a single post to a JsonNode, rendering its Markdown
  ## source into HTML (used by templates)
  result = postJson(post)
  result["content"] = %(renderHtml(post))
  result["content_markdown"] = %resolvePostRefs(post.content)

proc configJson(): JsonNode =
  ## Converts the global StupidGreen configuration to a JsonNode
  fromJson(toJson(globalStupidGreenConfig))

template pageNotFound(): JsonNode =
  ## Shared local data for the 4xx fallback view (a template so `&*`
  ## expands within the route handler, where `req` is in scope)
  &*{
    "post": {
      "meta": {
        "title": "Page Not Found",
        "description": "The page you are looking for does not exist."
      },
    },
    "config": configJson(),
    "currentLang": viewLang(""),
    "siteLangs": %(supportedLangs()),
    "translations": translationsArray(initTable[string, string]())
  }

proc baseUrl(): string =
  ## Returns the configured base URL without a trailing slash
  result = globalStupidGreenConfig.metadata.url
  while result.len > 0 and result[^1] == '/':
    result.setLen(result.len - 1)

proc homepageIntro(lang = ""): string =
  ## Returns the rendered homepage intro content: for a language, from
  ## `pages/index.<lang>.md` (falling back to the default intro); by
  ## default from `pages/index.md`, otherwise `posts/index.md`.
  if lang.len > 0:
    let lurl = prefixUrl(lang, "/")
    if gMarkdownService.pages.hasKey(lurl):
      return renderHtml(gMarkdownService.pages[lurl])
    if gMarkdownService.posts.hasKey(lurl):
      return renderHtml(gMarkdownService.posts[lurl])
  if gMarkdownService.pages.hasKey("/"):
    result = renderHtml(gMarkdownService.pages["/"])
  elif gMarkdownService.posts.hasKey("/"):
    result = renderHtml(gMarkdownService.posts["/"])

proc pagePath(n: int; lang = ""): string =
  ## Returns the URL of a blog index page, prefixed for non-default
  ## languages when the feature is enabled.
  prefixUrl(lang, if n == 1: "/" else: "/page/" & $n)

proc paginationUrls(page, totalPages: int; lang = ""): (string, string) =
  ## Computes the previous/next pagination URLs (language-prefixed).
  let prev = (if page > 1: pagePath(page - 1, lang) else: "")
  let next = (if page < totalPages: pagePath(page + 1, lang) else: "")
  (prev, next)

template indexLocal(lang: string; pageNum: int): JsonNode =
  ## Shared locals for the blog index (default and language homepages).
  ## A template so `&*` expands within the route handler, where `req`
  ## is in scope (common storage references it).
  let (posts, page, totalPages) =
    paginatePosts(postsFor(lang), pageNum, globalStupidGreenConfig.pagination.per_page)
  let (prevUrl, nextUrl) = paginationUrls(page, totalPages, lang)
  &*{
    "posts": postsJson(posts),
    "page": page,
    "totalPages": totalPages,
    "prevUrl": prevUrl,
    "nextUrl": nextUrl,
    "intro": homepageIntro(lang),
    "config": configJson(),
    "currentLang": viewLang(lang),
    "siteLangs": %(supportedLangs()),
    "translations": siteTranslations(proc(l: string): string = pagePath(pageNum, l))
  }

template postLocal(post: Post): JsonNode =
  ## Shared locals for a single post view (template: `&*` needs `req`).
  &*{
    "post": postJsonRendered(post),
    "config": configJson(),
    "currentLang": viewLang(post.meta.lang),
    "siteLangs": %(supportedLangs()),
    "translations": translationsArray(post.meta.translations)
  }

template pageLocal(page: Post): JsonNode =
  ## Shared locals for a standalone page view (template: `&*` needs `req`).
  &*{
    "page": postJsonRendered(page),
    "config": configJson(),
    "currentLang": viewLang(page.meta.lang),
    "siteLangs": %(supportedLangs()),
    "translations": translationsArray(page.meta.translations)
  }

proc defaultLlmsText(): string =
  ## Returns a helpful default `llms.txt` payload when no `llms.md` exists
  result = "# " & globalStupidGreenConfig.metadata.title.get("StupidGreen") & "\n\n" &
    globalStupidGreenConfig.metadata.description.get("") & "\n\n" &
    "Add an `llms.md` file to your project's `pages/` directory to customize this file.\n"

ctrl getHomepage:
  ## renders the homepage: the blog index (post cards) with an optional
  ## intro from `pages/index.md` (or `posts/index.md`). In pages mode
  ## `/` renders `pages/index.md` through its layout view instead.
  if globalStupidGreenConfig.mode == modePages:
    if gMarkdownService.pages.hasKey("/") and
        not gMarkdownService.pages["/"].meta.draft:
      let home = gMarkdownService.pages["/"]
      render(resolvePageView(home.meta.layout, "page"), local = &*{
        "page": postJsonRendered(home),
        "config": configJson(),
        "currentLang": viewLang(home.meta.lang),
        "siteLangs": %(supportedLangs()),
        "translations": translationsArray(home.meta.translations)
      })
    else:
      render("errors.4xx", local = pageNotFound(), httpCode = Http404)
    return
  render("index", local = indexLocal("", 1))

ctrl getPagePage:
  ## renders a paginated index page (blog mode only)
  if globalStupidGreenConfig.mode == modePages:
    render("errors.4xx", local = pageNotFound(), httpCode = Http404)
    return
  let pageNum = req.params["page"].parseInt
  render("index", local = indexLocal("", pageNum))

ctrl getPostsSlug:
  ## renders a single post (blog mode only)
  if globalStupidGreenConfig.mode == modePages:
    render("errors.4xx", local = pageNotFound(), httpCode = Http404)
    return
  let url = "/posts/" & req.params["slug"]
  if gMarkdownService.posts.hasKey(url):
    render("post", local = postLocal(gMarkdownService.posts[url]))
  else:
    render("errors.4xx", local = &*{
      "post": {
        "meta": {
          "title": "Page Not Found",
          "description": "The page you are looking for does not exist."
        },
      },
      "config": configJson(),
      "currentLang": viewLang(""),
      "siteLangs": %(supportedLangs()),
      "translations": translationsArray(initTable[string, string]())
    }, httpCode = Http404)

ctrl getTagsTag:
  ## renders a tag archive page (blog mode only)
  if globalStupidGreenConfig.mode == modePages:
    render("errors.4xx", local = pageNotFound(), httpCode = Http404)
    return
  let tagSlug = req.params["tag"]
  let posts = tagsFor("").getOrDefault(tagSlug, @[])
  let tagName = tagNameFor("", tagSlug)
  render("tag", local = &*{
    "tag": tagName,
    "tagSlug": tagSlug,
    "posts": postsJson(posts),
    "config": configJson(),
    "currentLang": viewLang(""),
    "siteLangs": %(supportedLangs()),
    "translations": siteTranslations(proc(l: string): string = prefixUrl(l, "/tags/" & tagSlug))
  })

ctrl getCategoriesCategory:
  ## renders a category archive page (blog mode only)
  if globalStupidGreenConfig.mode == modePages:
    render("errors.4xx", local = pageNotFound(), httpCode = Http404)
    return
  let catSlug = req.params["category"]
  let posts = categoriesFor("").getOrDefault(catSlug, @[])
  let catName = categoryNameFor("", catSlug)
  render("category", local = &*{
    "category": catName,
    "categorySlug": catSlug,
    "posts": postsJson(posts),
    "config": configJson(),
    "currentLang": viewLang(""),
    "siteLangs": %(supportedLangs()),
    "translations": siteTranslations(proc(l: string): string = prefixUrl(l, "/categories/" & catSlug))
  })

ctrl getSearch:
  ## renders the search results page.
  ## The rendering of the search results is done at client side
  ## using JavaScript, which fetches the search results from the
  ## getResultsJson endpoint.
  render("search", local = &*{
    "config": configJson(),
    "currentLang": viewLang(""),
    "siteLangs": %(supportedLangs()),
    "translations": siteTranslations(proc(l: string): string = prefixUrl(l, "/search"))
  })

ctrl getResultsJson:
  ## returns search results as JSON
  var resultsArray = newJArray()
  for entry in spotlight().getEntries():
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
  json(%*{
    "results": resultsArray
  })

ctrl getFeedXml:
  ## returns the RSS/Atom feed as XML (blog mode only, default language)
  if globalStupidGreenConfig.mode == modePages:
    render("errors.4xx", local = pageNotFound(), httpCode = Http404)
    return
  let xml = feedXml(
    postsFor(""),
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
  ## renders standalone pages (from the `pages/` directory) or a 4xx fallback.
  ## A page front-matter `layout` selects a custom theme view.
  let url = "/" & req.params["slug"]
  if gMarkdownService.pages.hasKey(url):
    let page = gMarkdownService.pages[url]
    render(resolvePageView(page.meta.layout, "page"), local = pageLocal(page))
  else:
    render("errors.4xx", local = &*{
      "post": {
        "meta": {
          "title": "Page Not Found",
          "description": "The page you are looking for does not exist."
        },
      },
      "config": configJson(),
      "currentLang": viewLang(""),
      "siteLangs": %(supportedLangs()),
      "translations": translationsArray(initTable[string, string]())
    }, httpCode = Http404)

template renderPageUrl(url: string) =
  ## Renders the page at `url` or the 4xx fallback (a template so
  ## `render` expands within the route handler, where it is in scope).
  if gMarkdownService.pages.hasKey(url):
    let page = gMarkdownService.pages[url]
    render(resolvePageView(page.meta.layout, "page"), local = pageLocal(page))
  else:
    render("errors.4xx", local = &*{
      "post": {
        "meta": {
          "title": "Page Not Found",
          "description": "The page you are looking for does not exist."
        },
      },
      "config": configJson(),
      "currentLang": viewLang(""),
      "siteLangs": %(supportedLangs()),
      "translations": translationsArray(initTable[string, string]())
    }, httpCode = Http404)

ctrl getLang:
  ## renders the language homepage (`/ro`): the language blog index
  ## with its intro, or a regular page when `lang` is not supported.
  ## In pages mode `/<lang>` renders the translated homepage or 404s.
  let (lang, ok) = effectiveLang(req.params["lang"])
  if not ok:
    renderPageUrl("/" & req.params["lang"])
    return
  if globalStupidGreenConfig.mode == modePages:
    let lurl = prefixUrl(lang, "/")
    if gMarkdownService.pages.hasKey(lurl) and
        not gMarkdownService.pages[lurl].meta.draft:
      let home = gMarkdownService.pages[lurl]
      render(resolvePageView(home.meta.layout, "page"), local = pageLocal(home))
    else:
      render("errors.4xx", local = pageNotFound(), httpCode = Http404)
    return
  render("index", local = indexLocal(lang, 1))

ctrl getLangPagePage:
  ## renders a paginated language index page (blog mode only)
  let (lang, ok) = effectiveLang(req.params["lang"])
  if not ok or globalStupidGreenConfig.mode == modePages:
    render("errors.4xx", local = pageNotFound(), httpCode = Http404)
    return
  let pageNum = req.params["page"].parseInt
  render("index", local = indexLocal(lang, pageNum))

ctrl getLangPostsSlug:
  ## renders a single translated post, a page at the same URL when one
  ## exists, or 404 when neither does (no default-language fallback).
  let (lang, ok) = effectiveLang(req.params["lang"])
  if not ok or globalStupidGreenConfig.mode == modePages:
    render("errors.4xx", local = pageNotFound(), httpCode = Http404)
    return
  let url = prefixUrl(lang, "/posts/" & req.params["slug"])
  if gMarkdownService.posts.hasKey(url):
    render(resolvePageView(gMarkdownService.posts[url].meta.layout, "post"),
      local = postLocal(gMarkdownService.posts[url]))
  elif gMarkdownService.pages.hasKey(url):
    let page = gMarkdownService.pages[url]
    render(resolvePageView(page.meta.layout, "page"), local = pageLocal(page))
  else:
    render("errors.4xx", local = pageNotFound(), httpCode = Http404)

ctrl getLangTagsTag:
  ## renders a language tag archive page (blog mode only)
  let (lang, ok) = effectiveLang(req.params["lang"])
  if not ok or globalStupidGreenConfig.mode == modePages:
    render("errors.4xx", local = pageNotFound(), httpCode = Http404)
    return
  let tagSlug = req.params["tag"]
  let posts = tagsFor(lang).getOrDefault(tagSlug, @[])
  render("tag", local = &*{
    "tag": tagNameFor(lang, tagSlug),
    "tagSlug": tagSlug,
    "posts": postsJson(posts),
    "config": configJson(),
    "currentLang": viewLang(lang),
    "siteLangs": %(supportedLangs()),
    "translations": siteTranslations(proc(l: string): string = prefixUrl(l, "/tags/" & tagSlug))
  })

ctrl getLangCategoriesCategory:
  ## renders a language category archive page (blog mode only)
  let (lang, ok) = effectiveLang(req.params["lang"])
  if not ok or globalStupidGreenConfig.mode == modePages:
    render("errors.4xx", local = pageNotFound(), httpCode = Http404)
    return
  let catSlug = req.params["category"]
  let posts = categoriesFor(lang).getOrDefault(catSlug, @[])
  render("category", local = &*{
    "category": categoryNameFor(lang, catSlug),
    "categorySlug": catSlug,
    "posts": postsJson(posts),
    "config": configJson(),
    "currentLang": viewLang(lang),
    "siteLangs": %(supportedLangs()),
    "translations": siteTranslations(proc(l: string): string = prefixUrl(l, "/categories/" & catSlug))
  })

ctrl getLangSearch:
  ## renders the language search page (results are filtered client side
  ## by `currentLang` using the `lang` field in `results.json`).
  let (lang, ok) = effectiveLang(req.params["lang"])
  if not ok:
    render("errors.4xx", local = pageNotFound(), httpCode = Http404)
    return
  render("search", local = &*{
    "config": configJson(),
    "currentLang": viewLang(lang),
    "siteLangs": %(supportedLangs()),
    "translations": siteTranslations(proc(l: string): string = prefixUrl(l, "/search"))
  })

ctrl getLangFeedXml:
  ## returns the language RSS/Atom feed as XML (blog mode only)
  let (lang, ok) = effectiveLang(req.params["lang"])
  if not ok or globalStupidGreenConfig.mode == modePages:
    render("errors.4xx", local = pageNotFound(), httpCode = Http404)
    return
  let xml = feedXml(
    postsFor(lang),
    globalStupidGreenConfig,
    baseUrl()
  )
  respond(Http200, xml, "application/xml")

ctrl getLangLlmsTxt:
  ## returns the translated `pages/llms.<lang>.md` contents as plain text
  let (lang, ok) = effectiveLang(req.params["lang"])
  if not ok:
    render("errors.4xx", local = pageNotFound(), httpCode = Http404)
    return
  let installPath = appInstance().applicationPaths.getInstallationPath
  let content = llmsTxtContent(installPath / "pages", lang)
  respond(Http200, (if content.len > 0: content else: defaultLlmsText()), "text/plain; charset=utf-8")

ctrl getLangSlug:
  ## renders a translated standalone page, a regular nested page when
  ## `lang` is not supported, or a 4xx fallback (no translation fallback).
  let (lang, ok) = effectiveLang(req.params["lang"])
  if not ok:
    renderPageUrl("/" & req.params["lang"] & "/" & req.params["slug"])
    return
  renderPageUrl(prefixUrl(lang, "/" & req.params["slug"]))
