# StupidGreen - A static blog generator for cool kids!
#
# (c) 2026 George Lemon | AGPL-3.0-or-later License
#          Made by Humans from OpenPeeps

## This Service provides Markdown parsing and rendering capabilities for StupidGreen.
##
## It monitors the `posts/` and `pages/` directories for markdown files, parses
## them into HTML, and serves the rendered content. Parsed content is persisted
## in a Boogie document store (WAL-based) for fast incremental rebuilds.
##
## Key Features:
## - Real-time monitoring of markdown files using Watchout
## - Parsing markdown files into HTML using Marvdown with configurable options
## - Extraction of metadata from the YAML front matter (title, date, tags, etc.)
## - Persistence of parsed content in a Boogie document store
## - Tag/category indexes and chronological navigation (older/newer) for posts
## - Standalone pages from the `pages/` directory mapped to their URL path
## - Spotlight search integration

import std/[os, tables, httpcore, strutils,
          options, sequtils, macros, times, algorithm]

import pkg/openparser/[json, html]
import pkg/[watchout, marvdown, kapsis/cli]
import pkg/boogie/stores/docstore

import pkg/supranim/core/[services, application, paths]
import pkg/supranim/network/websocket
import pkg/supranim/support/slug
import pkg/threading/rwlock

import ./tim, ./search, ./activitypub
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
        config*: StupidGreenConfig

    var
      contentPath: string     # the `posts/` directory
      pagesPath: string       # the `pages/` directory
      storePath: string
      store: DocumentStore
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

    proc getSlugHash(basePath, path: string): (string, string) =
      ## Computes the slug and URL for a given markdown file path
      var k = path.replace(basePath).replace(".md").slugify(allowSlash = true)
      if k == "index": k = "/"
      let url = if k == "/": "/" else: "/posts/" & k
      result = (k, url)

    proc getPageUrl(basePath, path: string): string =
      ## Computes the URL for a page file. `index.md` maps to its parent
      ## directory (the directory's first page), e.g. `pages/index.md` -> `/`
      ## and `pages/projects/index.md` -> `/projects`.
      var segments = path.replace(basePath).replace(".md").split('/').filterIt(it.len > 0)
      if segments.len > 0 and segments[^1] == "index":
        segments.setLen(segments.len - 1)
      result = "/" & segments.join("/")

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

      # slug & url
      var slug = ""
      var url = ""
      if isPage:
        url = getPageUrl(basePath, path)
      else:
        let pathSlug = getSlugHash(basePath, path)
        if pathSlug[1] == "/":
          # `posts/index.md` is the homepage, always at `/`
          (slug, url) = pathSlug
        elif shouldSlugFromTitle(meta):
          let titleSlug = title.slugify()
          if titleSlug.len > 0 and titleSlug != "index":
            slug = titleSlug
            url = "/posts/" & titleSlug
          else:
            (slug, url) = pathSlug
        else:
          (slug, url) = pathSlug

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

      # table of contents
      var toc: seq[Heading]
      for heading, anchor in md.getSelectors():
        toc.add(Heading(id: anchor, title: heading, level: 0))

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
          fileMtime: fileTime.toUnix,
          filePath: path
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

    proc rebuildIndex() =
      ## Rebuilds the in-memory sorted list, navigation and tag/category indexes
      var sorted: seq[Post] = @[]
      for url, post in gMarkdownService.posts:
        if url == "/" or post.meta.draft:
          continue
        sorted.add(post)
      sorted.sort(proc (a, b: Post): int = cmp(b.meta.dateUnix, a.meta.dateUnix))

      # chronological navigation (older/newer)
      for i in 0 ..< sorted.len:
        var nav = PostNavigation()
        if i > 0:
          nav.next = some(PostLink(title: sorted[i - 1].meta.title, url: sorted[i - 1].meta.url))
        if i < sorted.len - 1:
          nav.previous = some(PostLink(title: sorted[i + 1].meta.title, url: sorted[i + 1].meta.url))
        gMarkdownService.posts[sorted[i].meta.url].navigation = nav

      # tag/category indexes (keyed by tag slug)
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

    proc rebuildSearch() =
      ## Rebuilds the Spotlight search index from all non-draft posts
      let searchInstance = spotlight()
      searchInstance.clear()
      for url, post in gMarkdownService.posts:
        if post.meta.draft or url == "/":
          continue
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
          headings = some(headings)
        )

    proc loadFromStore() =
      ## Loads all persisted content from the Boogie document store
      gMarkdownService = MarkdownInstance(
        posts: newTable[string, Post](),
        pages: newTable[string, Post](),
        sorted: @[],
        byTag: newTable[string, seq[Post]](),
        byCategory: newTable[string, seq[Post]](),
        tagNames: newTable[string, string](),
        categoryNames: newTable[string, string](),
      )
      for key, doc in store.pairs:
        try:
          let post = fromJson(toJson(doc), Post)
          if key.startsWith("page:"):
            gMarkdownService.pages[post.meta.url] = post
          else:
            gMarkdownService.posts[post.meta.url] = post
        except:
          discard # skip corrupted documents

    proc llmsTxtContent*(pagesPath: string): string =
      ## Extracts the contents of the project's `pages/llms.md` file as plain
      ## text. If the file does not exist, an empty string is returned.
      let fpath = pagesPath / "llms.md"
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
      ## the document store and the in-memory tables
      let titleSlugs = not isPage and globalStupidGreenConfig.content.slugFromTitle
      for path in walkDirRec(dir, {pcFile}):
        let fpath = path.splitFile
        if fpath.ext != ".md" or fpath.name.startsWith("!"):
          # skip non-markdown files and temporary files prefixed with "!"
          continue
        if isPage and path.extractFilename == "llms.md":
          # `llms.md` is served as `/llms.txt`, not as a page
          continue
        if not titleSlugs:
          # fast path: skip unchanged files (only valid when the URL is
          # derived from the file path, which is always true for pages and
          # for posts when `slugFromTitle` is off)
          let url =
            if isPage: getPageUrl(dir, path)
            else: getSlugHash(dir, path)[1]
          let storeKey = (if isPage: "page:" else: "") & url
          let mtime = getLastModificationTime(path).toUnix
          if store.hasKey(storeKey):
            let existing = store.get(storeKey)
            if existing.isSome:
              try:
                let prev = fromJson(toJson(existing.get()), Post)
                if prev.meta.fileMtime >= mtime:
                  continue # skip unchanged files
              except:
                discard

        let post = parseMarkdownFile(dir, path, isPage)
        let url = post.meta.url
        let storeKey = (if isPage: "page:" else: "") & url
        var stalePathKey = ""
        if titleSlugs:
          # remove any stale key left over from a previous path-derived slug
          let pathKey = (if isPage: "page:" else: "") & getSlugHash(dir, path)[1]
          if pathKey != storeKey and store.hasKey(pathKey):
            stalePathKey = pathKey
        # skip the write when the stored document is already up-to-date
        var skipWrite = false
        if stalePathKey.len == 0 and store.hasKey(storeKey):
          let existing = store.get(storeKey)
          if existing.isSome:
            try:
              let prev = fromJson(toJson(existing.get()), Post)
              if prev.meta.fileMtime >= post.meta.fileMtime:
                skipWrite = true
            except:
              discard
        if not skipWrite:
          if stalePathKey.len > 0:
            discard store.delete(stalePathKey)
          store.putObj(storeKey, post)
        if isPage:
          gMarkdownService.pages[url] = post
        else:
          gMarkdownService.posts[url] = post

    proc scanMarkdownFiles*(contentPath, pagesPath: string) =
      ## Scans the posts and pages directories, parsing changed/new markdown
      ## files and rebuilding the in-memory indexes
      scanDir(contentPath, false)
      scanDir(pagesPath, true)
      rebuildIndex()
      rebuildSearch()
      store.checkpoint()

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
      if fileExists(path) and not (path.extractFilename == "llms.md" and path.startsWith(pagesPath)):
        let isPage = path.startsWith(pagesPath)
        let basePath = (if isPage: pagesPath else: contentPath)
        let post = parseMarkdownFile(basePath, path, isPage)
        let url = post.meta.url
        # find the previous entry: title-derived slugs mean the URL may not
        # match the file name, so resolve by `filePath` first, then fall back
        # to the path-derived key for entries persisted before it was tracked
        var previousUrl = findFileUrl(isPage, path)
        var wasPublished = false
        if previousUrl.len == 0:
          let pathUrl =
            if isPage: getPageUrl(basePath, path)
            else: getSlugHash(basePath, path)[1]
          let pathKey = (if isPage: "page:" else: "") & pathUrl
          if store.hasKey(pathKey):
            previousUrl = pathUrl
            try:
              let prev = fromJson(toJson(store.get(pathKey).get()), Post)
              wasPublished = not prev.meta.draft
            except:
              discard
        else:
          try:
            let prev = fromJson(toJson(store.get((if isPage: "page:" else: "") & previousUrl).get()), Post)
            wasPublished = not prev.meta.draft
          except:
            discard
        var nowPublished = false
        writeWith changeLocker:
          # a URL change (e.g. a title edit) replaces the old entry
          if previousUrl.len > 0 and previousUrl != url:
            let oldKey = (if isPage: "page:" else: "") & previousUrl
            discard store.delete(oldKey)
            if isPage:
              if gMarkdownService.pages.hasKey(previousUrl):
                gMarkdownService.pages.del(previousUrl)
            else:
              if gMarkdownService.posts.hasKey(previousUrl):
                gMarkdownService.posts.del(previousUrl)
          let storeKey = (if isPage: "page:" else: "") & url
          store.putObj(storeKey, post)
          if isPage:
            gMarkdownService.pages[url] = post
          else:
            gMarkdownService.posts[url] = post
          nowPublished = not post.meta.draft
          rebuildIndex()
          rebuildSearch()
          store.checkpoint()
        if not isPage:
          # a title change moved the URL: unpublish the old URL first so
          # federated feeds get a `Delete` for it
          if previousUrl.len > 0 and previousUrl != url:
            activitypub.removePost(previousUrl)
          activitypub.onPostChanged(post, renderHtml(post), wasPublished, nowPublished)
        notifyClients()

    proc onDelete(file: watchout.File) =
      ## Callback when a markdown file is deleted
      let path = file.getPath()
      let isPage = path.startsWith(pagesPath)
      let basePath = (if isPage: pagesPath else: contentPath)
      # resolve the URL by file path (title-derived slugs don't match the file
      # name); fall back to the path-derived key for pre-upgrade entries
      var url = findFileUrl(isPage, path)
      if url.len == 0:
        url =
          if isPage: getPageUrl(basePath, path)
          else: getSlugHash(basePath, path)[1]
      let storeKey = (if isPage: "page:" else: "") & url
      writeWith changeLocker:
        discard store.delete(storeKey)
        if isPage:
          if gMarkdownService.pages.hasKey(url):
            gMarkdownService.pages.del(url)
        else:
          if gMarkdownService.posts.hasKey(url):
            gMarkdownService.posts.del(url)
        rebuildIndex()
        rebuildSearch()
        store.checkpoint()
      if not isPage:
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

    proc openStore() =
      ## Opens the Boogie document store (replays the WAL + snapshot on open)
      store = openDocumentStore(storePath, "posts",
        defaultEncoding = deJson,
        checkpointEveryOps = 100,
        walFlushEveryOps = 100
      )
      loadFromStore()

    proc initMarkdownInstance*(app: Application, dbPath: string) =
      ## Opens the Boogie store and loads existing content (used by `build`)
      storePath = dbPath
      contentPath = app.applicationPaths.getInstallationPath / "posts"
      pagesPath = app.applicationPaths.getInstallationPath / "pages"
      createDir(storePath)
      createDir(contentPath)
      createDir(pagesPath)
      const defaultHomePage = staticRead(storagePath / "stubs" / "index.md")
      if not fileExists(contentPath / "index.md"):
        writeFile(contentPath / "index.md", defaultHomePage)
      setupMarkdownOptions()
      openStore()

    proc init*(app: Application) =
      ## Initialize the Markdown service and start monitoring files
      contentPath = app.applicationPaths.getInstallationPath / "posts"
      pagesPath = app.applicationPaths.getInstallationPath / "pages"
      storePath = app.applicationPaths.getInstallationPath / "storage" / "stupidgreen"

      createDir(contentPath)
      createDir(pagesPath)
      createDir(storePath)

      const defaultHomePage = staticRead(storagePath / "stubs" / "index.md")
      if not fileExists(contentPath / "index.md"):
        # ensure there's at least an index.md to start with
        writeFile(contentPath / "index.md", defaultHomePage)

      setupMarkdownOptions()

      openStore()

      # Create a new Watchout instance to monitor markdown files
      watcher = newWatchout(@[contentPath, pagesPath], some("*.md"))
      watcher.onChange = onChange
      watcher.onFound = onFound
      watcher.onDelete = onDelete
      watcher.start() # in the background (new thread)

      # initial scan of existing markdown files
      scanMarkdownFiles(contentPath, pagesPath)
