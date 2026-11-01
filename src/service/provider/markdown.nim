# StupidGreen - A static blog generator for cool kids!
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps

## This Service provides Markdown parsing and rendering capabilities for StupidGreen.
##
## It monitors the `posts/` and `pages/` directories for markdown files, parses
## them into HTML, and serves the rendered content. Parsed content is persisted
## in a lock-free FBE snapshot (`stupidgreen.db`) for fast incremental rebuilds.
##
## Key Features:
## - Real-time monitoring of markdown files using Watchout
## - Parsing markdown files into HTML using Marvdown with configurable options
## - Extraction of metadata from the YAML front matter (title, date, tags, etc.)
## - Persistence of parsed content in a lock-free FBE snapshot (`stupidgreen.db`)
## - Tag/category indexes and chronological navigation (older/newer) for posts
## - Standalone pages from the `pages/` directory mapped to their URL path
## - Spotlight search integration

import std/[os, tables, httpcore, strutils,
          options, sequtils, macros, times, algorithm]

import pkg/openparser/[json, html, fbe]
import pkg/[watchout, marvdown, kapsis/cli]
import pkg/kapsis/interactive/prompts

import pkg/supranim/core/[services, application, paths]
import pkg/supranim/network/websocket
import pkg/supranim/support/slug
import pkg/threading/rwlock

import ./tim, ./search, ./activitypub, ./syntax, ./dbcodec
import ../../app/structs

export structs

initService Markdown[Global]:
  backend do:
    type
      MarkdownInstance* = ref object
        posts*: TableRef[string, Post]          # map of post URLs to posts
        pages*: TableRef[string, Post]          # map of page URLs to pages
        sorted*: seq[Post]                      # published posts sorted by date (desc)
        byTag*: TableRef[string, seq[Post]]     # tag slug -> posts
        byCategory*: TableRef[string, seq[Post]] # category slug -> posts
        tagNames*: TableRef[string, string]     # tag slug -> display name
        categoryNames*: TableRef[string, string] # category slug -> display name
        sortedByLang*: TableRef[string, seq[Post]] # lang -> published posts (date desc)
        byTagByLang*: TableRef[string, TableRef[string, seq[Post]]] # lang -> tag slug -> posts
        byCategoryByLang*: TableRef[string, TableRef[string, seq[Post]]] # lang -> category slug -> posts
        tagNamesByLang*: TableRef[string, TableRef[string, string]] # lang -> tag slug -> name
        categoryNamesByLang*: TableRef[string, TableRef[string, string]] # lang -> category slug -> name
        config*: StupidGreenConfig

    var
      contentPath: string     # the `posts/` directory
      pagesPath: string       # the `pages/` directory
      dbFile: string          # the `stupidgreen.db` snapshot file
      watcher*: Watchout
      hasChanges: bool
      gMarkdownService*: MarkdownInstance
      wsClients: seq[WsConnection]
      changeLocker = createRwLock()
      allowedTags = @[tagA, tagAbbr, tagB, tagBlockquote, tagBr,
                    tagCode, tagDel, tagEm, tagH1, tagH2, tagH3, tagH4, tagH5, tagH6,
                    tagHr, tagI, tagImg, tagLi, tagOl, tagP, tagPre, tagStrong, tagTable,
                    tagTbody, tagTd, tagTh, tagThead, tagTr, tagUl, tagMark, tagSmall,
                    tagSub, tagSup, tagDiv]

    var
      markdownOptions = MarkdownOptions(
        allowTagsByType: none(TagType),
        allowInlineStyle: false,
        allowHtmlAttributes: false,
        enableAnchors: true,
        htmlTableClasses: some(@["table", "table-hover"]),
        enableComponents: false
      )

    proc langEnabled*(): bool =
      ## Whether multilingual support is active (opt-in via
      ## `languages.enable` in the site config).
      globalStupidGreenConfig.languagesEnabled()

    proc defaultLang*(): string =
      ## The default content language code (bare file names,
      ## unprefixed URLs). Falls back to `"en"` when unset.
      globalStupidGreenConfig.defaultLangCode()

    proc supportedLangs*(): seq[string] =
      ## Supported language codes (lowercased, deduplicated).
      ## Falls back to the default language when unset.
      globalStupidGreenConfig.supportedLangCodes()

    proc splitLangSuffix*(relNoExt: string): (string, string, bool) =
      ## Splits a `.md`-less relative path into (base, lang, ok).
      ## With the feature disabled every file is default-language
      ## content: returns (relNoExt, "", true). See `splitLangSuffixRaw`.
      splitLangSuffixRaw(relNoExt, langEnabled(), defaultLang(), supportedLangs())

    proc checkLangCollision*(baseRel, lang, path: string; isPage: bool) =
      ## Warns when a default-language page URL sits under a language
      ## prefix (`pages/ro/about.md` -> `/ro/about`), where translated
      ## content always wins at serve/build time.
      if not isPage or not langEnabled() or lang != defaultLang():
        return
      let segs = baseRel.split('/').filterIt(it.len > 0)
      if segs.len > 0 and segs[0] in supportedLangs() and
          segs[0] != defaultLang():
        displayWarning("`" & path & "` maps to `/" & segs.join("/") &
          "`, which collides with the `" & segs[0] &
          "` language prefix; translated content takes precedence there.")

    proc splitContentPath*(basePath, path: string): (string, string, bool) =
      ## Splits a content file path into (relative base without `.md`
      ## or lang suffix, lang code, ok). See `splitLangSuffix`.
      let rel = path.replace(basePath).replace(".md")
      if not langEnabled():
        return (rel, "", true)
      splitLangSuffix(rel)

    proc prefixUrl*(lang, url: string): string =
      ## Prefixes `url` with `/<lang>` for non-default languages
      ## (`/about` -> `/ro/about`, `/` -> `/ro`). Default-language
      ## and empty-lang URLs pass through unchanged.
      prefixUrlFor(lang, url, langEnabled(), defaultLang())

    proc isDefaultLangUrl*(url: string): bool =
      ## Whether `url` serves default-language content (unprefixed, or
      ## the feature is disabled). Used to keep federation on the
      ## default language only.
      ## the feature is disabled). Used to keep federation on the
      ## default language only.
      if not langEnabled():
        return true
      for code in supportedLangs():
        if code == defaultLang():
          continue
        if url == "/" & code or url.startsWith("/" & code & "/"):
          return false
      true

    proc pubLang*(lang: string): string =
      ## Language code exposed to templates as `currentLang`
      ## ("" when the languages feature is disabled).
      if langEnabled():
        if lang.len > 0: lang else: defaultLang()
      else: ""

    proc pubLangs*(): seq[string] =
      ## Supported language codes exposed to templates as `siteLangs`.
      supportedLangs()

    proc translationsArray*(translations: Table[string, string]): JsonNode =
      ## Template-ready `[{lang, url}]` array (sorted by lang) for the
      ## language switcher. Empty when the document has no translations.
      result = newJArray()
      var langs = toSeq(keys(translations))
      langs.sort()
      for lang in langs:
        var o = newJObject()
        o["lang"] = %(lang)
        o["url"] = %(translations[lang])
        result.add(o)

    proc siteTranslations*(mkUrl: proc(lang: string): string {.closure.}): JsonNode =
      ## Template-ready translations array for archive/index/search
      ## views: the same view in every supported language (default
      ## language unprefixed). Single entry when the feature is off.
      var t = initTable[string, string]()
      for code in supportedLangs():
        let l = if code == defaultLang(): "" else: code
        t[code] = mkUrl(l)
      translationsArray(t)

    proc isLlmsFile*(path: string): bool =
      ## Whether `path` is an llms source file: `llms.md`, plus
      ## `llms.<lang>.md` when the languages feature is enabled
      ## (served as `/<lang>/llms.txt`, never as a page).
      let name = path.extractFilename
      if name == "llms.md":
        return true
      langEnabled() and name.startsWith("llms.") and name.endsWith(".md")

    proc slugUrlForPost*(baseRel, lang: string): (string, string) =
      ## Computes (slug, path-part URL) for a post from its suffix-less
      ## relative name. The caller applies `prefixUrl` for the final URL
      ## when the slug comes from the title instead of the file name.
      var k = baseRel.slugify(allowSlash = true)
      if k == "index": k = "/"
      let url = if k == "/": "/" else: "/posts/" & k
      result = (k, url)

    proc pageUrlFor*(baseRel, lang: string): string =
      ## Computes the URL for a page file from its suffix-less relative
      ## name. `index.md` maps to its parent directory, e.g.
      ## `pages/projects/index.md` -> `/projects` (and with a lang
      ## suffix, `pages/projects/index.ro.md` -> `/ro/projects`).
      var segments = baseRel.split('/').filterIt(it.len > 0)
      if segments.len > 0 and segments[^1] == "index":
        segments.setLen(segments.len - 1)
      prefixUrl(lang, "/" & segments.join("/"))

    proc getSlugHash(basePath, path: string): (string, string, string) =
      ## Computes the (slug, URL, lang) for a post file. With the
      ## languages feature enabled non-default languages get prefixed
      ## URLs; unsupported suffixes fall back to the default language
      ## (callers skip such files before reaching this proc).
      let (base, lang, ok) = splitContentPath(basePath, path)
      let langOrDefault = if ok: lang else: defaultLang()
      let (k, url) = slugUrlForPost(base, langOrDefault)
      result = (k, prefixUrl(langOrDefault, url), langOrDefault)

    proc getPageUrl(basePath, path: string): (string, string) =
      ## Computes the (URL, lang) for a page file. `index.md` maps to
      ## its parent directory; non-default languages get prefixed URLs.
      let (base, lang, ok) = splitContentPath(basePath, path)
      let langOrDefault = if ok: lang else: defaultLang()
      result = (pageUrlFor(base, langOrDefault), langOrDefault)

    proc findFileUrl(isPage: bool, path: string): string =
      ## Finds the URL of a post/page whose source file matches `path`, using
      ## the `filePath` stored on the parsed document (title-derived slugs mean
      ## the URL may not match the file name). Returns "" when not found, e.g.
      ## for entries persisted before `filePath` was tracked.
      if isPage:
        for u, p in gMarkdownService.pages:
          if p.meta.filePath == path:
            return u
      else:
        for u, p in gMarkdownService.posts:
          if p.meta.filePath == path:
            return u
      result = ""

    proc stripHtml(s: string): string =
      ## Removes HTML tags from a string, decoding common entities
      result = ""
      var i = 0
      var inTag = false
      while i < s.len:
        case s[i]
        of '<': inTag = true
        of '>': inTag = false
        else:
          if not inTag: result.add(s[i])
        inc i
      result = result.replace("&amp;", "&").replace("&lt;", "<")
        .replace("&gt;", ">").replace("&quot;", "\"").replace("&#39;", "'")

    proc makeExcerpt(content: string, maxLen = 160): string =
      ## Generates a plain-text excerpt from rendered HTML content.
      ## The full text is returned when the post body is not significantly
      ## longer than `maxLen` (within a tolerance window), otherwise the
      ## text is truncated at a word boundary and suffixed with "…".
      var src = content
      # drop code blocks
      var stripped = ""
      var i = 0
      while i < src.len:
        if i + 4 <= src.len and src[i .. i + 3] == "<pre":
          let endIdx = src.find("</pre>", i)
          if endIdx >= 0:
            i = endIdx + 6
            continue
        stripped.add(src[i])
        inc i
      # drop anchor links (e.g., `<a class="anchor-link">🔗</a>`)
      src = ""
      i = 0
      while i < stripped.len:
        if stripped[i] == '<' and stripped[i .. min(i + 21, stripped.len - 1)].contains("anchor-link"):
          let endIdx = stripped.find("</a>", i)
          if endIdx >= 0:
            i = endIdx + 4
            continue
        src.add(stripped[i])
        inc i
      result = stripHtml(src).strip().replace("\n", " ")
      while result.contains("  "):
        result = result.replace("  ", " ")
      result = result.replace("🔗", "")
      let tolerance = max(40, maxLen div 4)
      if result.len > maxLen + tolerance:
        result = result[0 .. maxLen - 1].strip()
        let lastSpace = result.rfind(' ')
        if lastSpace > maxLen div 2:
          result.setLen(lastSpace)
        result = result.strip() & "…"

    proc computeReadingTime(mdSource: string, wpm = 200): int =
      ## Estimates the reading time in minutes based on the word count
      var src = mdSource
      # strip the YAML front matter
      if src.startsWith("---"):
        let endIdx = src.find("\n---", 3)
        if endIdx >= 0:
          src = src[endIdx + 4 .. ^1]
      var words = 0
      var inCode = false
      for line in src.splitLines():
        if line.startsWith("```"):
          inCode = not inCode
          continue
        if inCode: continue
        for _ in line.splitWhitespace():
          inc words
      result = max(1, words div wpm)

    proc shouldSlugFromTitle(meta: JsonNode): bool =
      ## Whether the post uses a title-derived slug: the global config is on
      ## and the file does not opt out with `slugify: false` front matter.
      if not globalStupidGreenConfig.content.slugFromTitle:
        return false
      if meta.kind == JObject and meta.hasKey("slugify"):
        try:
          if not meta["slugify"].getBool():
            return false
        except:
          discard
      true

    proc parseMarkdownFile(basePath, path: string; isPage = false): Post =
      ## Parses a markdown file into a Post, extracting front matter metadata.
      ## When `isPage` is true, the file is treated as a standalone page.
      ## When the `slugFromTitle` config is enabled (and the file does not opt
      ## out with `slugify: false` front matter), the post slug is derived from
      ## the title instead of the file name.
      let
        mdSource = readFile(path)
        fileTime = getLastModificationTime(path)
      var md = newMarkdown(mdSource, markdownOptions)
      let meta: JsonNode = toJson(md.getHeader()).fromJson()
      let htmlContent: string = md.toHtml()

      # title
      var title = ""
      if meta.kind == JObject and meta.hasKey("title"):
        title = meta["title"].getStr()
      if title.len == 0:
        title = md.getTitle()

      # slug & url (& lang)
      var slug = ""
      var url = ""
      var lang = ""
      if isPage:
        (url, lang) = getPageUrl(basePath, path)
      else:
        let pathSlug = getSlugHash(basePath, path)
        lang = pathSlug[2]
        if pathSlug[1] == "/":
          # `posts/index.md` is the homepage, always at `/`
          # (or `/<lang>` for a translated homepage intro)
          (slug, url) = (pathSlug[0], pathSlug[1])
        elif shouldSlugFromTitle(meta):
          let titleSlug = title.slugify()
          if titleSlug.len > 0 and titleSlug != "index":
            slug = titleSlug
            url = prefixUrl(lang, "/posts/" & titleSlug)
          else:
            (slug, url) = (pathSlug[0], pathSlug[1])
        else:
          (slug, url) = (pathSlug[0], pathSlug[1])

      # date
      var dateStr = ""
      if meta.kind == JObject and meta.hasKey("date"):
        dateStr = meta["date"].getStr()
      var dateTime: Time = fileTime
      if dateStr.len > 0:
        try:
          let dt = parse(dateStr.strip(), "yyyy-MM-dd")
          dateTime = dateTime(dt.year, dt.month, dt.monthday, 0, 0, 0, 0, utc()).toTime
        except:
          discard
      let dateUnix: int64 = dateTime.toUnix

      # excerpt (front matter `excerpt` overrides the body-derived one)
      var excerpt = ""
      if meta.kind == JObject and meta.hasKey("excerpt"):
        excerpt = meta["excerpt"].getStr()
      if excerpt.len == 0:
        excerpt = makeExcerpt(htmlContent, globalStupidGreenConfig.content.excerpt_length)
      if excerpt.len == 0:
        # fall back to the title so listings always have some text
        excerpt = title

      # author
      var author = ""
      if meta.kind == JObject and meta.hasKey("author"):
        author = meta["author"].getStr()
      if author.len == 0 and globalStupidGreenConfig.metadata.author.isSome:
        author = globalStupidGreenConfig.metadata.author.get()

      # tags & categories
      var tags: seq[Tag]
      var categories: seq[Tag]
      if meta.kind == JObject and meta.hasKey("tags"):
        for t in meta["tags"]:
          let name = t.getStr()
          tags.add(Tag(name: name, slug: slugify(name)))
      if meta.kind == JObject and meta.hasKey("categories"):
        for c in meta["categories"]:
          let name = c.getStr()
          categories.add(Tag(name: name, slug: slugify(name)))

      # draft / cover / series
      var draft = false
      if meta.kind == JObject and meta.hasKey("draft"):
        draft = meta["draft"].getBool()
      var cover = ""
      if meta.kind == JObject and meta.hasKey("cover"):
        cover = meta["cover"].getStr()
      var series = ""
      if meta.kind == JObject and meta.hasKey("series"):
        series = meta["series"].getStr()

      # layout (front matter `layout` selects a custom theme view,
      # i.e. `views/<layout>.timl`; empty selects the default view)
      var layout = ""
      if meta.kind == JObject and meta.hasKey("layout"):
        layout = meta["layout"].getStr().strip()

      # table of contents (`getSelectorItems` yields document order with
      # explicit fields: `anchor` is the slugified id, `title` the heading
      # text, `level` the heading level 1-6). Nested items get a tree
      # branch marker: "mid" unless last in their sibling group ("last").
      var toc: seq[Heading]
      for item in md.getSelectorItems():
        toc.add(Heading(id: item.anchor, title: item.title, level: item.level, branch: ""))
      if toc.len > 0:
        var baseLevel = toc[0].level
        for h in toc:
          baseLevel = min(baseLevel, h.level)
        for i in 0 ..< toc.len:
          if toc[i].level > baseLevel:
            # last in its sibling group when the next item back at this
            # level or higher is an ancestor (or there is none) — a
            # following sibling at the same level means more to come
            var isLast = true
            for j in i + 1 ..< toc.len:
              if toc[j].level <= toc[i].level:
                isLast = toc[j].level < toc[i].level
                break
            toc[i].branch = if isLast: "last" else: "mid"

      result = Post(
        meta: PostMeta(
          title: title,
          date: dateStr,
          dateUnix: dateUnix,
          excerpt: excerpt,
          author: author,
          cover: cover,
          slug: slug,
          url: url,
          series: series,
          tags: tags,
          categories: categories,
          draft: draft,
          layout: layout,
          fileMtime: fileTime.toUnix,
          filePath: path,
          lang: lang
        ),
        content: mdSource,
        last_updated: fileTime.format("yyyy-MM-dd HH:mm:ss"),
        reading_time: computeReadingTime(mdSource),
        toc: toc
      )

    proc renderHtml*(post: Post): string =
      ## Renders the post's Markdown source into HTML on demand
      var md = newMarkdown(post.content, markdownOptions)
      result = md.toHtml()

    proc groupKeyFor(basePath, filePath: string): string =
      ## Groups translations of the same document: the suffix-less
      ## relative name. Returns "" for files that predate `filePath`
      ## tracking or fall outside the content dirs.
      if filePath.len == 0 or not filePath.startsWith(basePath):
        return ""
      let (base, _, ok) = splitContentPath(basePath, filePath)
      if not ok:
        return ""
      base

    proc rebuildTranslations() =
      ## (Re)builds `meta.translations` (lang -> URL, including the
      ## document's own language) for every post and page by grouping
      ## same-base files. No-op when the languages feature is disabled.
      if not langEnabled():
        return
      for url in toSeq(keys(gMarkdownService.posts)):
        gMarkdownService.posts[url].meta.translations.clear()
      for url in toSeq(keys(gMarkdownService.pages)):
        gMarkdownService.pages[url].meta.translations.clear()
      var groups = initTable[string, seq[(bool, string)]]()
      for url, post in gMarkdownService.posts:
        let key = groupKeyFor(contentPath, post.meta.filePath)
        if key.len > 0:
          groups.mgetOrPut("post:" & key, @[]).add((false, url))
      for url, page in gMarkdownService.pages:
        let key = groupKeyFor(pagesPath, page.meta.filePath)
        if key.len > 0:
          groups.mgetOrPut("page:" & key, @[]).add((true, url))
      for _, members in groups:
        var byLang = initTable[string, string]()
        for (isPage, url) in members:
          let lang =
            if isPage: gMarkdownService.pages[url].meta.lang
            else: gMarkdownService.posts[url].meta.lang
          let code = if lang.len > 0: lang else: defaultLang()
          byLang[code] = url
        for (isPage, url) in members:
          if isPage:
            gMarkdownService.pages[url].meta.translations = byLang
          else:
            gMarkdownService.posts[url].meta.translations = byLang

    proc rebuildIndex() =
      ## Rebuilds the in-memory sorted lists, navigation and tag/category
      ## indexes. With the languages feature enabled every language gets
      ## its own group (same-language older/newer navigation and tag
      ## archives); the legacy `sorted`/`byTag`/… fields keep serving
      ## the default language so single-language behavior is unchanged.
      let enabled = langEnabled()
      let defLang = defaultLang()
      var groups = initTable[string, seq[Post]]()
      for url, post in gMarkdownService.posts:
        if post.meta.draft or post.meta.slug == "/":
          continue
        let key =
          if not enabled: ""
          elif post.meta.lang.len > 0: post.meta.lang
          else: defLang
        groups.mgetOrPut(key, @[]).add(post)
      for key in toSeq(keys(groups)):
        groups[key].sort(proc (a, b: Post): int = cmp(b.meta.dateUnix, a.meta.dateUnix))

      # chronological navigation (older/newer), within each language
      for _, lst in groups:
        for i in 0 ..< lst.len:
          var nav = PostNavigation()
          if i > 0:
            nav.next = some(PostLink(title: lst[i - 1].meta.title, url: lst[i - 1].meta.url))
          if i < lst.len - 1:
            nav.previous = some(PostLink(title: lst[i + 1].meta.title, url: lst[i + 1].meta.url))
          gMarkdownService.posts[lst[i].meta.url].navigation = nav

      let defKey = if enabled: defLang else: ""
      let sorted = groups.getOrDefault(defKey, @[])

      # tag/category indexes for the default language (legacy fields)
      gMarkdownService.byTag = newTable[string, seq[Post]]()
      gMarkdownService.byCategory = newTable[string, seq[Post]]()
      gMarkdownService.tagNames = newTable[string, string]()
      gMarkdownService.categoryNames = newTable[string, string]()
      for post in sorted:
        for tag in post.meta.tags:
          if not gMarkdownService.byTag.hasKey(tag.slug):
            gMarkdownService.byTag[tag.slug] = @[]
          gMarkdownService.byTag[tag.slug].add(post)
          if not gMarkdownService.tagNames.hasKey(tag.slug):
            gMarkdownService.tagNames[tag.slug] = tag.name
        for cat in post.meta.categories:
          if not gMarkdownService.byCategory.hasKey(cat.slug):
            gMarkdownService.byCategory[cat.slug] = @[]
          gMarkdownService.byCategory[cat.slug].add(post)
          if not gMarkdownService.categoryNames.hasKey(cat.slug):
            gMarkdownService.categoryNames[cat.slug] = cat.name

      gMarkdownService.sorted = sorted

      # per-language indexes (used by language routes and builds)
      gMarkdownService.sortedByLang = newTable[string, seq[Post]]()
      gMarkdownService.byTagByLang = newTable[string, TableRef[string, seq[Post]]]()
      gMarkdownService.byCategoryByLang = newTable[string, TableRef[string, seq[Post]]]()
      gMarkdownService.tagNamesByLang = newTable[string, TableRef[string, string]]()
      gMarkdownService.categoryNamesByLang = newTable[string, TableRef[string, string]]()
      for lang, lst in groups:
        gMarkdownService.sortedByLang[lang] = lst
        var byTag = newTable[string, seq[Post]]()
        var byCat = newTable[string, seq[Post]]()
        var tagNames = newTable[string, string]()
        var catNames = newTable[string, string]()
        for post in lst:
          for tag in post.meta.tags:
            if not byTag.hasKey(tag.slug):
              byTag[tag.slug] = @[]
            byTag[tag.slug].add(post)
            if not tagNames.hasKey(tag.slug):
              tagNames[tag.slug] = tag.name
          for cat in post.meta.categories:
            if not byCat.hasKey(cat.slug):
              byCat[cat.slug] = @[]
            byCat[cat.slug].add(post)
            if not catNames.hasKey(cat.slug):
              catNames[cat.slug] = cat.name
        gMarkdownService.byTagByLang[lang] = byTag
        gMarkdownService.byCategoryByLang[lang] = byCat
        gMarkdownService.tagNamesByLang[lang] = tagNames
        gMarkdownService.categoryNamesByLang[lang] = catNames

      rebuildTranslations()

    proc rebuildSearch() =
      ## Rebuilds the Spotlight search index from all non-draft posts.
      ## In pages mode the blogging system is disabled, so standalone
      ## pages (including the homepage) are indexed instead.
      let searchInstance = spotlight()
      searchInstance.clear()
      proc indexEntry(url: string, post: Post) =
        var headings: seq[string]
        for heading in post.toc:
          headings.add(heading.title)
        searchInstance.addEntry(
          url,
          url,
          post.meta.title,
          description =
            if post.meta.excerpt.len > 0: some(post.meta.excerpt)
            else: none(string),
          headings = some(headings),
          lang = post.meta.lang
        )
      for url, post in gMarkdownService.posts:
        if post.meta.draft or url == "/":
          continue
        indexEntry(url, post)
      if globalStupidGreenConfig.mode == modePages:
        for url, page in gMarkdownService.pages:
          if page.meta.draft:
            continue
          indexEntry(url, page)

    proc writeMarkdownInstanceFields(b: var Buffer, inst: MarkdownInstance) =
      ## Serializes the cached posts/pages maps (indexes are rebuilt
      ## in-memory via `rebuildIndex`, and search via `rebuildSearch`)
      b.writeField(1'u16, proc (bb: var Buffer) = bb.writePostMap(inst.posts))
      b.writeField(2'u16, proc (bb: var Buffer) = bb.writePostMap(inst.pages))

    proc handleMarkdownInstanceField(fid: uint16, fsz: int, b: var Buffer,
                                     into: var MarkdownInstance) =
      case fid
      of 1'u16: into.posts = b.readPostMap()
      of 2'u16: into.pages = b.readPostMap()
      else: discard

    proc encodeMarkdownInstance(inst: MarkdownInstance): Buffer =
      ## Serializes a `MarkdownInstance` into an FBE payload buffer
      ## (wrap with `writeDbFile` for the signature envelope)
      result = initBuffer()
      encodeRootFrom(result, inst, writeMarkdownInstanceFields, DbCodecVersion)

    proc decodeMarkdownInstance(b: var Buffer): MarkdownInstance =
      ## Deserializes a `MarkdownInstance` from an FBE payload buffer
      ## (unwrap with `readDbFile` first)
      result = MarkdownInstance(
        posts: newTable[string, Post](),
        pages: newTable[string, Post](),
        sorted: @[],
        byTag: newTable[string, seq[Post]](),
        byCategory: newTable[string, seq[Post]](),
        tagNames: newTable[string, string](),
        categoryNames: newTable[string, string](),
        sortedByLang: newTable[string, seq[Post]](),
        byTagByLang: newTable[string, TableRef[string, seq[Post]]](),
        byCategoryByLang: newTable[string, TableRef[string, seq[Post]]](),
        tagNamesByLang: newTable[string, TableRef[string, string]](),
        categoryNamesByLang: newTable[string, TableRef[string, string]](),
      )
      var outVer: uint32
      b.decodeRootInto(result, handleMarkdownInstanceField, outVer)

    proc freshService() =
      ## Starts with empty in-memory tables; the scan below rebuilds them
      gMarkdownService = MarkdownInstance(
        posts: newTable[string, Post](),
        pages: newTable[string, Post](),
        sorted: @[],
        byTag: newTable[string, seq[Post]](),
        byCategory: newTable[string, seq[Post]](),
        tagNames: newTable[string, string](),
        categoryNames: newTable[string, string](),
        sortedByLang: newTable[string, seq[Post]](),
        byTagByLang: newTable[string, TableRef[string, seq[Post]]](),
        byCategoryByLang: newTable[string, TableRef[string, seq[Post]]](),
        tagNamesByLang: newTable[string, TableRef[string, string]](),
        categoryNamesByLang: newTable[string, TableRef[string, string]](),
      )

    proc removeLegacyStoreFiles() =
      ## Best-effort removal of pre-FBE Boogie files (lock, WAL, snapshot).
      ## Unlinking is safe even if an old binary still runs: it holds open
      ## file descriptors, and the new snapshot lives in `stupidgreen.db`.
      let legacyDir = dbFile.parentDir / "stupidgreen"
      for f in ["posts.lock", "posts.wal", "posts.ddb"]:
        try: removeFile(legacyDir / f)
        except: discard

    proc loadFromStore() =
      ## Loads cached content from the FBE snapshot. Anything but `dbOk`
      ## (missing, stale or foreign file) starts fresh; the scan below
      ## rebuilds the cache from the markdown sources.
      freshService()
      var payload: Buffer
      if readDbFile(dbFile, payload) != dbOk:
        return
      try:
        let inst = decodeMarkdownInstance(payload)
        if not inst.posts.isNil:
          gMarkdownService.posts = inst.posts
        if not inst.pages.isNil:
          gMarkdownService.pages = inst.pages
      except:
        freshService()

    proc saveDb() =
      ## Persists the in-memory posts/pages maps to the FBE snapshot.
      ## A cache write failure must never break a build or the dev server.
      try:
        writeDbFile(dbFile, encodeMarkdownInstance(gMarkdownService))
        removeLegacyStoreFiles()
      except:
        discard

    proc llmsTxtContent*(pagesPath: string, lang = ""): string =
      ## Extracts the contents of the project's `pages/llms.md` file as plain
      ## text (or `pages/llms.<lang>.md` when a translation exists).
      ## If no file exists, an empty string is returned.
      var fpath = pagesPath / "llms.md"
      if lang.len > 0:
        let lpath = pagesPath / ("llms." & lang & ".md")
        if fileExists(lpath):
          fpath = lpath
      if not fileExists(fpath):
        return ""
      var src = readFile(fpath)
      # strip the YAML front matter (if any)
      if src.startsWith("---"):
        let endIdx = src.find("\n---", 3)
        if endIdx >= 0:
          src = src[endIdx + 4 .. ^1]
      result = src.strip()

    proc scanDir(dir: string, isPage: bool) =
      ## Scans a content directory, parsing changed/new markdown files into
      ## the in-memory tables (persisted later via `saveDb`)
      let titleSlugs = not isPage and globalStupidGreenConfig.content.slugFromTitle

      proc cachedAt(url: string): Post =
        ## Cached document for `url`, or an empty Post when absent
        if isPage:
          if gMarkdownService.pages.hasKey(url):
            return gMarkdownService.pages[url]
        else:
          if gMarkdownService.posts.hasKey(url):
            return gMarkdownService.posts[url]
        result = Post()

      proc forget(url: string) =
        ## Drops a stale cached document for `url`
        if isPage:
          if gMarkdownService.pages.hasKey(url):
            gMarkdownService.pages.del(url)
        else:
          if gMarkdownService.posts.hasKey(url):
            gMarkdownService.posts.del(url)

      for path in walkDirRec(dir, {pcFile}):
        let fpath = path.splitFile
        if fpath.ext != ".md" or fpath.name.startsWith("!"):
          # skip non-markdown files and temporary files prefixed with "!"
          continue
        if isPage and isLlmsFile(path):
          # `llms.md` (or `llms.<lang>.md`) is served as plain text,
          # never as a page
          continue
        if langEnabled():
          let (base, lang, ok) = splitContentPath(dir, path)
          if not ok:
            displayWarning("Skipping `" & path &
              "`: unsupported language suffix (see `languages.supported`).")
            continue
          checkLangCollision(base, lang, path, isPage)
        if not titleSlugs:
          # fast path: skip unchanged files (only valid when the URL is
          # derived from the file path, which is always true for pages and
          # for posts when `slugFromTitle` is off)
          let url =
            if isPage: getPageUrl(dir, path)[0]
            else: getSlugHash(dir, path)[1]
          let mtime = getLastModificationTime(path).toUnix
          let prev = cachedAt(url)
          if prev.meta.url.len > 0 and prev.meta.fileMtime >= mtime:
            continue # skip unchanged files

        let post = parseMarkdownFile(dir, path, isPage)
        let url = post.meta.url
        if titleSlugs:
          # remove any stale entry left over from a previous path-derived slug
          let pathUrl = getSlugHash(dir, path)[1]
          if pathUrl != url:
            forget(pathUrl)
        # skip the write when the cached document is already up-to-date
        let prev = cachedAt(url)
        if prev.meta.url.len == 0 or prev.meta.fileMtime < post.meta.fileMtime:
          if isPage:
            gMarkdownService.pages[url] = post
          else:
            gMarkdownService.posts[url] = post

    proc scanMarkdownFiles*(contentPath, pagesPath: string) =
      ## Scans the posts and pages directories, parsing changed/new markdown
      ## files and rebuilding the in-memory indexes. In pages mode the
      ## blogging system is disabled, so `posts/` is never scanned
      ## (and may not exist).
      if globalStupidGreenConfig.mode == modePages:
        if dirExists(pagesPath):
          scanDir(pagesPath, true)
      else:
        if dirExists(contentPath):
          scanDir(contentPath, false)
        if dirExists(pagesPath):
          scanDir(pagesPath, true)
      rebuildIndex()
      rebuildSearch()
      saveDb()

    # WebSocket Connection - Callbacks
    proc onMessageCallback(ws: WsConnection, kind: WsFrameKind, data: openArray[byte]) =
      {.gcsafe.}:
        if kind == wsText:
          let s = cast[string](data.toSeq)
          ws.sendText("echo: " & s)

    proc onOpenCallback*(ws: WsConnection) =
      {.gcsafe.}:
        writeWith changeLocker:
          ws.sendText("Markdown Service WebSocket Connected")
          wsClients.add(ws)

    proc onClose*(ws: WsConnection, code: int, reason: string) =
      {.gcsafe.}:
        writeWith changeLocker:
          wsClients = wsClients.filterIt(it != ws)

    proc onError*(ws: WsConnection, err: string) =
      discard

    proc notifyClients() =
      {.gcsafe.}:
        writeWith changeLocker:
          hasChanges = false
        readWith changeLocker:
          for ws in wsClients:
            ws.sendText("1")

    # Watchout callbacks
    proc onFound(file: watchout.File) =
      ## Callback when a markdown file is found
      discard

    proc onChange(file: watchout.File) =
      ## Callback when a markdown file is changed
      let path = file.getPath()
      if globalStupidGreenConfig.mode == modePages and not path.startsWith(pagesPath):
        return # pages-only site: the blogging system is disabled
      if fileExists(path) and not (isLlmsFile(path) and path.startsWith(pagesPath)):
        let isPage = path.startsWith(pagesPath)
        let basePath = (if isPage: pagesPath else: contentPath)
        if langEnabled():
          let (base, lang, ok) = splitContentPath(basePath, path)
          if not ok:
            displayWarning("Skipping `" & path &
              "`: unsupported language suffix (see `languages.supported`).")
            return
          checkLangCollision(base, lang, path, isPage)
        let post = parseMarkdownFile(basePath, path, isPage)
        let url = post.meta.url
        # find the previous entry: title-derived slugs mean the URL may not
        # match the file name, so resolve by `filePath` first, then fall back
        # to the path-derived key for entries persisted before it was tracked
        var previousUrl = findFileUrl(isPage, path)
        var wasPublished = false
        if previousUrl.len == 0:
          let pathUrl =
            if isPage: getPageUrl(basePath, path)[0]
            else: getSlugHash(basePath, path)[1]
          if (isPage and gMarkdownService.pages.hasKey(pathUrl)) or
             (not isPage and gMarkdownService.posts.hasKey(pathUrl)):
            previousUrl = pathUrl
            try:
              let prev =
                if isPage: gMarkdownService.pages[pathUrl]
                else: gMarkdownService.posts[pathUrl]
              wasPublished = not prev.meta.draft
            except:
              discard
        else:
          try:
            let prev =
              if isPage: gMarkdownService.pages[previousUrl]
              else: gMarkdownService.posts[previousUrl]
            wasPublished = not prev.meta.draft
          except:
            discard
        var nowPublished = false
        writeWith changeLocker:
          # a URL change (e.g. a title edit) replaces the old entry
          if previousUrl.len > 0 and previousUrl != url:
            if isPage:
              if gMarkdownService.pages.hasKey(previousUrl):
                gMarkdownService.pages.del(previousUrl)
            else:
              if gMarkdownService.posts.hasKey(previousUrl):
                gMarkdownService.posts.del(previousUrl)
          if isPage:
            gMarkdownService.pages[url] = post
          else:
            gMarkdownService.posts[url] = post
          nowPublished = not post.meta.draft
          rebuildIndex()
          rebuildSearch()
          saveDb()
        if not isPage:
          # a title change moved the URL: unpublish the old URL first so
          # federated feeds get a `Delete` for it (default language only)
          if previousUrl.len > 0 and previousUrl != url and
              (post.meta.lang.len == 0 or post.meta.lang == defaultLang()):
            activitypub.removePost(previousUrl)
          if post.meta.lang.len == 0 or post.meta.lang == defaultLang():
            activitypub.onPostChanged(post, renderHtml(post), wasPublished, nowPublished)
        notifyClients()

    proc onDelete(file: watchout.File) =
      ## Callback when a markdown file is deleted
      let path = file.getPath()
      if globalStupidGreenConfig.mode == modePages and not path.startsWith(pagesPath):
        return # pages-only site: the blogging system is disabled
      let isPage = path.startsWith(pagesPath)
      let basePath = (if isPage: pagesPath else: contentPath)
      # resolve the URL by file path (title-derived slugs don't match the file
      # name); fall back to the path-derived key for pre-upgrade entries
      var url = findFileUrl(isPage, path)
      if url.len == 0:
        url =
          if isPage: getPageUrl(basePath, path)[0]
          else: getSlugHash(basePath, path)[1]
      writeWith changeLocker:
        if isPage:
          if gMarkdownService.pages.hasKey(url):
            gMarkdownService.pages.del(url)
        else:
          if gMarkdownService.posts.hasKey(url):
            gMarkdownService.posts.del(url)
        rebuildIndex()
        rebuildSearch()
        saveDb()
      if not isPage and isDefaultLangUrl(url):
        # federation stays on the default language: translated URLs
        # were never announced, so there is nothing to retract
        activitypub.removePost(url)
      notifyClients()

    proc escapeHtmlText(s: string): string =
      ## Escapes HTML special characters for safe text/attribute output
      result = s.multiReplace(("&", "&amp;"), ("<", "&lt;"), (">", "&gt;"),
                              ("\"", "&quot;"), ("'", "&#39;"))

    proc postCardHtml(post: Post): string =
      ## Builds the HTML card rendered for a `@<post>.md` reference
      result = "<div class=\"post-ref\"><a class=\"post-ref__link\" href=\"" &
        post.meta.url & "\">"
      if post.meta.cover.len > 0:
        result.add("<img class=\"post-ref__cover\" src=\"" &
          escapeHtmlText(post.meta.cover) & "\" alt=\"\" loading=\"lazy\">")
      result.add("<div class=\"post-ref__body\">")
      if post.meta.date.len > 0:
        result.add("<span class=\"post-ref__date\">" &
          escapeHtmlText(post.meta.date) & "</span>")
      result.add("<h3 class=\"post-ref__title\">" &
        escapeHtmlText(post.meta.title) & "</h3>")
      if post.meta.excerpt.len > 0:
        result.add("<p class=\"post-ref__excerpt\">" &
          escapeHtmlText(post.meta.excerpt) & "</p>")
      result.add("</div></a></div>")

    proc findPostRef(target: string): Post =
      ## Resolves a `@<target>.md` reference to a post, matching by file name,
      ## path or title-derived slug. Returns an empty Post when the referenced
      ## markdown file does not exist as a post (so it stays plain text).
      if gMarkdownService.isNil:
        return Post()
      for url, post in gMarkdownService.posts:
        if post.meta.filePath.len > 0 and
           extractFilename(post.meta.filePath) == target:
          return post
        if post.meta.filePath.len > 0 and
           post.meta.filePath.endsWith("/" & target):
          return post
        if post.meta.slug.len > 0 and post.meta.slug & ".md" == target:
          return post
      result = Post()

    proc postReferenceTransform(line: string): string =
      ## Custom marvdown parsing hook: replaces `@<post>.md` references with a
      ## post card when the referenced markdown file exists as a post. Unknown
      ## references (e.g. `@somebrand.md`) are left as plain text.
      result = newStringOfCap(line.len)
      var i = 0
      while i < line.len:
        if line[i] == '@' and (i == 0 or line[i - 1] != '\\'):
          var j = i + 1
          var name = ""
          while j < line.len and line[j] in {'a'..'z', 'A'..'Z', '0'..'9',
                                             '.', '_', '-', '/'}:
            name.add(line[j])
            inc j
          if name.endsWith(".md") and name.len > 3 and
             (j >= line.len or line[j] notin {'a'..'z', 'A'..'Z', '0'..'9', '_', '-'}):
            let post = findPostRef(name)
            if post.meta.url.len > 0:
              result.add(postCardHtml(post))
              i = j
              continue
        result.add(line[i])
        inc i

    proc resolvePostRefs*(content: string): string =
      ## Replaces `@<post>.md` references with portable Markdown links
      ## (`[title](url)`). Unknown references are left as plain text.
      ## Used for the "Copy as Markdown" share payload so copied content
      ## stays meaningful outside StupidGreen.
      result = newStringOfCap(content.len)
      var i = 0
      while i < content.len:
        if content[i] == '@' and (i == 0 or content[i - 1] != '\\'):
          var j = i + 1
          var name = ""
          while j < content.len and content[j] in {'a'..'z', 'A'..'Z', '0'..'9',
                                                  '.', '_', '-', '/'}:
            name.add(content[j])
            inc j
          if name.endsWith(".md") and name.len > 3 and
             (j >= content.len or content[j] notin {'a'..'z', 'A'..'Z', '0'..'9', '_', '-'}):
            let post = findPostRef(name)
            if post.meta.url.len > 0:
              result.add("[" & post.meta.title & "](" & post.meta.url & ")")
              i = j
              continue
        result.add(content[i])
        inc i

    proc setupMarkdownOptions() =
      ## Configure Marvdown options based on the StupidGreen configuration
      var allowedHtmlTags: seq[HtmlTag]
      if isSome(globalStupidGreenConfig.content.allowedRawHtmlTags):
        allowedHtmlTags = concat(allowedTags, globalStupidGreenConfig.content.allowedRawHtmlTags.get())
      else:
        allowedHtmlTags = allowedTags
      markdownOptions.allowed = allowedHtmlTags
      markdownOptions.lazyloadIframes = globalStupidGreenConfig.content.lazyloadIframes
      markdownOptions.lazyloadVideos = globalStupidGreenConfig.content.lazyloadVideos
      markdownOptions.lazyloadImages = globalStupidGreenConfig.content.lazyloadImages
      markdownOptions.customTransform =
        if globalStupidGreenConfig.content.postReferences:
          postReferenceTransform
        else:
          nil
      # backend code highlighting via SweetSyntax (no client-side script)
      loadThemeSyntax()
      code_line_numbers = globalStupidGreenConfig.content.code_line_numbers
      highlight_strip_lines = globalStupidGreenConfig.content.highlight_strip_lines
      markdownOptions.codeBlockTransform = highlightCode

    proc initMarkdownInstance*(app: Application, dbPath: string) =
      ## Loads the FBE snapshot and scans content (used by `build`)
      dbFile = dbPath
      contentPath = app.applicationPaths.getInstallationPath / "posts"
      pagesPath = app.applicationPaths.getInstallationPath / "pages"
      createDir(dbFile.parentDir)
      if globalStupidGreenConfig.mode == modePages:
        # pages-only site: never create `posts/`, the blogging
        # system is disabled
        discard
      else:
        createDir(contentPath)
      createDir(pagesPath)
      # Note: never create content files here. The default `posts/index.md`
      # is written only once by `stupidgreen new`; a deleted index.md stays
      # deleted.
      setupMarkdownOptions()
      loadFromStore()

    proc init*(app: Application) =
      ## Initialize the Markdown service and start monitoring files
      contentPath = app.applicationPaths.getInstallationPath / "posts"
      pagesPath = app.applicationPaths.getInstallationPath / "pages"
      dbFile = app.applicationPaths.getInstallationPath / "storage" / "stupidgreen.db"

      if globalStupidGreenConfig.mode == modePages:
        # pages-only site: never create `posts/`, the blogging
        # system is disabled
        discard
      else:
        createDir(contentPath)
      createDir(pagesPath)
      createDir(dbFile.parentDir)

      # Note: never create content files here. The default `posts/index.md`
      # is written only once by `stupidgreen new`; a deleted index.md stays
      # deleted.

      setupMarkdownOptions()

      loadFromStore()

      # Create a new Watchout instance to monitor markdown files
      let watchDirs =
        if globalStupidGreenConfig.mode == modePages: @[pagesPath]
        else: @[contentPath, pagesPath]
      watcher = newWatchout(watchDirs, some("*.md"))
      watcher.onChange = onChange
      watcher.onFound = onFound
      watcher.onDelete = onDelete
      watcher.start() # in the background (new thread)

      # initial scan of existing markdown files
      scanMarkdownFiles(contentPath, pagesPath)
