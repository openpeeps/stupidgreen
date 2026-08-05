# StupidGreen - A static blog generator for cool kids!
#
# (c) 2026 George Lemon | AGPL-3.0-or-later License
#          Made by Humans from OpenPeeps

## This module provides feed (RSS/Atom) and sitemap generation for StupidGreen.
##
## RSS and Atom feeds are generated using the `openparser` RSS and Atom
## modules, while the sitemap is generated as raw XML.

import std/[times, strutils, algorithm, options]

import pkg/openparser/[rss, feed]

import ./markdown
import ../../app/structs

proc rfc2822*(t: Time): string =
  ## Format a `Time` value as an RFC-2822 date string (e.g., "Tue, 15 Jan 2026 10:00:00 GMT")
  result = t.utc().format("ddd, dd MMM yyyy HH:mm:ss") & " GMT"

proc rfc3339*(t: Time): string =
  ## Format a `Time` value as an RFC-3339 date string (e.g., "2026-01-15T10:00:00Z")
  result = t.utc().format("yyyy-MM-dd'T'HH:mm:ss'Z'")

proc postDate*(post: Post): Time =
  ## Parse the post date from its unix timestamp
  post.meta.dateUnix.fromUnix

proc escapeXml*(s: string): string =
  ## Escape XML special characters in a string
  result = s
  result = result.replace("&", "&amp;")
  result = result.replace("<", "&lt;")
  result = result.replace(">", "&gt;")
  result = result.replace("\"", "&quot;")

proc publishedPosts*(posts: seq[Post], limit = -1): seq[Post] =
  ## Returns the published posts (non-drafts, excluding the homepage intro),
  ## sorted by date descending. If `limit` is greater than zero, only the
  ## first `limit` posts are returned.
  result = @[]
  for post in posts:
    if post.meta.draft or post.meta.url == "/":
      continue
    result.add(post)
  result.sort(proc (a, b: Post): int = cmp(b.meta.dateUnix, a.meta.dateUnix))
  if limit > 0 and result.len > limit:
    result.setLen(limit)

proc feedUrl*(baseUrl: string, kind: string): string =
  ## Returns the feed URL based on the configured feed kind
  if kind == "atom": baseUrl & "/feed.xml" else: baseUrl & "/feed.xml"

proc rssFeed*(posts: seq[Post], config: StupidGreenConfig, baseUrl: string): string =
  ## Generate an RSS 2.0 feed XML string from the given posts
  let
    siteTitle = config.metadata.title.get("StupidGreen")
    siteDescription = config.metadata.description.get("")
    feedItems = publishedPosts(posts, config.feed.limit)

  var rss = RssFeed(
    title: siteTitle,
    link: baseUrl,
    description: siteDescription,
    copyright: "",
    pubDate: rfc2822(now().toTime),
    lastBuildDate: rfc2822(now().toTime),
    atomSelfLink: some(feedUrl(baseUrl, "rss"))
  )
  if config.metadata.logo.isSome:
    rss.image.url = baseUrl & config.metadata.logo.get
    rss.image.title = siteTitle
    rss.image.link = baseUrl

  for post in feedItems:
    var item = RssItem(
      title: some(post.meta.title),
      link: some(baseUrl & post.meta.url),
      description: some(post.meta.excerpt),
      pubDate: some(rfc2822(postDate(post))),
      guid: some(baseUrl & post.meta.url)
    )
    if post.meta.categories.len > 0:
      item.category = some(post.meta.categories[0].name)
    if post.meta.cover.len > 0:
      item.mediaContent = some(RssMediaContent(
        url: some(baseUrl & post.meta.cover),
        mediaType: some("image/jpeg")
      ))
    rss.items.add(item)

  result = toRssXml(rss)

proc atomFeed*(posts: seq[Post], config: StupidGreenConfig, baseUrl: string): string =
  ## Generate an Atom feed XML string from the given posts
  let
    siteTitle = config.metadata.title.get("StupidGreen")
    siteDescription = config.metadata.description.get("")
    authorName = config.metadata.author.get("")
    feedItems = publishedPosts(posts, config.feed.limit)

  var atom = AtomFeed(
    id: baseUrl & "/",
    title: AtomText(kind: "text", value: siteTitle),
    updated: if feedItems.len > 0: rfc3339(postDate(feedItems[0])) else: rfc3339(now().toTime),
    subtitle: some(AtomText(kind: "text", value: siteDescription)),
    links: @[
      AtomLink(href: feedUrl(baseUrl, "atom"), rel: some("self"), mimeType: some("application/atom+xml")),
      AtomLink(href: baseUrl, rel: some("alternate"), mimeType: some("text/html"))
    ]
  )
  if authorName.len > 0:
    atom.authors = @[AtomPerson(name: authorName)]

  for post in feedItems:
    var entry = AtomEntry(
      id: baseUrl & post.meta.url,
      title: AtomText(kind: "text", value: post.meta.title),
      updated: rfc3339(postDate(post)),
      published: some(rfc3339(postDate(post))),
      links: @[AtomLink(href: baseUrl & post.meta.url, rel: some("alternate"), mimeType: some("text/html"))],
      summary: some(AtomText(kind: "html", value: post.meta.excerpt)),
      content: some(AtomContent(kind: some("html"), value: some(renderHtml(post))))
    )
    if authorName.len > 0:
      entry.authors = @[AtomPerson(name: authorName)]
    for tag in post.meta.tags:
      entry.categories.add(AtomCategory(term: tag.name))
    atom.entries.add(entry)

  result = toAtomXml(atom)

proc feedXml*(posts: seq[Post], config: StupidGreenConfig, baseUrl: string): string =
  ## Generate the feed XML string based on the configured feed kind ("rss" or "atom")
  if config.feed.kind == "atom":
    result = atomFeed(posts, config, baseUrl)
  else:
    result = rssFeed(posts, config, baseUrl)

proc sitemapXml*(posts, pages: seq[Post], config: StupidGreenConfig, baseUrl: string): string =
  ## Generate a sitemap.xml string from the given posts, pages and configuration
  result.add("<?xml version=\"1.0\" encoding=\"UTF-8\"?>")
  result.add("<urlset xmlns=\"http://www.sitemaps.org/schemas/sitemap/0.9\">")

  # homepage
  result.add("<url><loc>" & escapeXml(baseUrl & "/") & "</loc></url>")

  var urlEntries: seq[tuple[loc, lastmod: string]] = @[]
  for post in publishedPosts(posts):
    urlEntries.add((baseUrl & post.meta.url, rfc2822(postDate(post))))

  # standalone pages (the homepage entry is already added above)
  for page in pages:
    if page.meta.draft or page.meta.url == "/":
      continue
    urlEntries.add((baseUrl & page.meta.url, ""))

  # collect tag/category archive URLs
  var tags: seq[string] = @[]
  var categories: seq[string] = @[]
  for post in publishedPosts(posts):
    for tag in post.meta.tags:
      if tag.slug notin tags: tags.add(tag.slug)
    for cat in post.meta.categories:
      if cat.slug notin categories: categories.add(cat.slug)
  for tag in tags:
    urlEntries.add((baseUrl & "/tags/" & tag, ""))
  for cat in categories:
    urlEntries.add((baseUrl & "/categories/" & cat, ""))

  for entry in urlEntries:
    result.add("<url><loc>" & escapeXml(entry.loc) & "</loc>")
    if entry.lastmod.len > 0:
      result.add("<lastmod>" & entry.lastmod & "</lastmod>")
    result.add("</url>")

  result.add("</urlset>")
