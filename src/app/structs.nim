# StupidGreen - A static blog generator for cool kids!
#
# (c) 2026 George Lemon | AGPL-3.0-or-later License
#          Made by Humans from OpenPeeps

import std/[options, strutils]
import pkg/openparser/html

type
  AppearanceDefaultTheme* = enum
    themeSystem = "system"
      ## Follow the user's OS theme preference
    themeLight = "light"
      ## Light theme mode
    themeDark = "dark"
      ## Dark theme mode

  PostLink* = object
    ## Represents a link to another post (e.g., prev/next navigation)
    title*: string
      ## The title of the linked post
    url*: string
      ## The URL path of the linked post

  PostNavigation* = object
    ## Represents the bottom navigation links for a post
    previous*: Option[PostLink]
      ## Older post navigation item
    next*: Option[PostLink]
      ## Newer post navigation item

  Heading* = object
    ## A single heading entry within a post's table of contents
    id*: string
      ## The anchor id of the heading
    title*: string
      ## The heading text
    level*: int
      ## The heading level (1-6)

  PostMeta* = object
    ## Metadata for a blog post, extracted from the YAML front matter
    title*: string
      ## The title of the post
    date*: string
      ## The publication date of the post (e.g., "2026-01-15")
    dateUnix*: int64
      ## The publication date as a unix timestamp (for sorting)
    excerpt*: string
      ## A short summary of the post
    author*: string
      ## The author of the post
    cover*: string
      ## Optional cover image path
    slug*: string
      ## The URL slug of the post
    url*: string
      ## The URL path of the post (`/posts/{slug}`)
    series*: string
      ## An optional series this post belongs to
    tags*: seq[Tag]
      ## The tags associated with the post
    categories*: seq[Tag]
      ## The categories associated with the post
    draft*: bool
      ## Whether the post is a draft (excluded from builds)
    fileMtime*: int64
      ## The file modification time, used for change detection
    filePath*: string
      ## The absolute path of the source markdown file, used to map file
      ## events back to the post URL when slugs are derived from the title

  Tag* = object
    ## A tag or category associated with a post
    name*: string
      ## The display name of the tag
    slug*: string
      ## The URL-friendly slug of the tag

  Post* = object
    ## A blog post. The store persists the Markdown source (AST input);
    ## HTML is rendered on demand when serving or building pages.
    meta*: PostMeta
      ## The post metadata
    content*: string
      ## The raw Markdown source of the post
    last_updated*: string
      ## The last updated timestamp of the post
    reading_time*: int
      ## The estimated reading time in minutes
    toc*: seq[Heading]
      ## The table of contents for the post
    navigation*: PostNavigation
      ## Navigation information for the post (older/newer links)

  StupidGreenNavItem* = ref object
    ## Represents an item in the StupidGreen navigation bar
    title*: string
      ## The display title of the navigation item
    url*: string
      ## The URL path the navigation item points to
    icon*: Option[string]
      ## An optional icon associated with the navigation item

  StupidGreenFooter* = object
    ## Represents the footer configuration for StupidGreen
    text: Option[string]
      ## Footer text content
    links: Option[seq[StupidGreenNavItem]]
      ## Footer links configuration

  StupidGreenMetadata* = object
    ## Metadata information for the StupidGreen site
    url*: string
      ## The base URL of the blog
    logo*: Option[string]
      ## URL or path to the logo image for the site
    logo_keep_gradient*: bool
      ## Whether to keep the original colors of the logo
    title*: Option[string]
      ## The title of the blog
    description*: Option[string]
      ## A short description of the blog for SEO purposes
    keywords*: Option[seq[string]]
      ## A list of keywords for SEO purposes
    author*: Option[string]
      ## The default author for the blog

  ContentSettings* = object
    ## Settings related to Markdown processing in StupidGreen
    allowedRawHtmlTags*: Option[seq[HtmlTag]]
      ## A list of allowed raw HTML tags in Markdown content
    showReadingTime*: bool
      ## Whether to show the reading time on posts
    showLastUpdated*: bool
      ## Whether to show the "Last Updated" timestamp on posts
    lastDateUpdatedFormat*: string = "yyyy-MM-dd HH:mm:ss"
      ## The format string for displaying the "Last Updated" timestamp
    enableAutoFormatLinks*: bool = true
      ## Whether to automatically format URLs as clickable links in Markdown content
    bottom_navigation*: bool
      ## Whether to enable bottom navigation links (older/newer) on posts
    codeHighlightTheme*: string = "default"
      ## The code syntax highlighting theme to use
    excerpt_length*: int = 160
      ## The maximum number of characters for auto-generated excerpts
    readMoreText*: string = "Continue reading this story"
      ## The label of the "read more" link shown on post cards in listings
    lazyloadIframes*: bool  = true
      ## Whether to lazyload iframes in Markdown content (default: false)
    lazyloadVideos*: bool  = true
      ## Whether to lazyload videos and audio in Markdown content (default: false)
    lazyloadImages*: bool = true
      ## Whether to lazyload images in Markdown content (default: false)
    slugFromTitle*: bool = true
      ## Whether to derive post slugs from the front-matter title instead of
      ## the file name. Per-file `slugify: false` in the front matter disables
      ## this for that post (falls back to the file name).
    postReferences*: bool = true
      ## Enable `@<post>.md` references in Markdown content that render as a
      ## post card. Only references that resolve to an existing post are
      ## converted; unknown references (e.g. `@somebrand.md`) stay as text.

  HeaderSearchSettings* = object
    ## Settings related to the search functionality in the header
    enable*: bool = true
      ## Whether to enable search functionality in the header
    index_meta_data*: bool = true
      ## Whether to index metadata for search
    index_page_titles*: bool = true
      ## Whether to index page titles for search

  HeaderSettings* = object
    ## General settings for StupidGreen
    search*: HeaderSearchSettings
      ## Whether to enable search functionality
    notification*: Option[string]
      ## Optional HTML content for displaying a
      ## notification banner in the header

  AppearanceSettings* = object
    ## Appearance-related settings for StupidGreen
    show_theme_switcher*: bool = true
      ## Whether to show a theme switcher (light/dark mode) in the header
    default_theme*: AppearanceDefaultTheme = AppearanceDefaultTheme.themeSystem
      ## The default theme for the site
    container_width*: string = "col-lg-10 mx-auto"
      ## Bootstrap 5 container width class for the main content area
    content_width*: string = "col-lg-8"
      ## Bootstrap 5 column width class for the content area
    background_noise_opacity*: float = 0.03
      ## Opacity of the background noise texture (0.0 to 1.0)

  PaginationSettings* = object
    ## Pagination settings for the blog index
    per_page*: int = 10
      ## The number of posts per page

  FeedSettings* = object
    ## Settings for the blog feed
    enable*: bool = true
      ## Whether to generate the feed
    limit*: int = 20
      ## The maximum number of posts in the feed
    kind*: string = "rss"
      ## The feed kind: "rss" or "atom"

  ActivityPubSettings* = object
    ## Settings for the ActivityPub federated mode
    enable*: bool = false
      ## Whether to enable ActivityPub federation (served by `StupidGreen start`)
    username*: string = "blog"
      ## The Fediverse username (handle) of the blog actor,
      ## e.g. `blog` results in `@blog@<metadata.url host>`
    name*: string = ""
      ## The display name of the blog actor
    summary*: string = ""
      ## A short biography shown on the actor's profile
    icon*: string = ""
      ## Optional avatar URL for the blog actor

  StupidGreenConfig* = object
    ## Configuration options for StupidGreen.
    ## This object is automatically populated from `StupidGreen.config.yaml`
    ## or `StupidGreen.config.json` file in the current directory.
    metadata*: StupidGreenMetadata
      ## Metadata information for the site
    appearance*: AppearanceSettings
      ## Appearance-related settings for StupidGreen
    header*: HeaderSettings
      ## Header-related settings for StupidGreen
    content*: ContentSettings
      ## Content-related settings for StupidGreen
    pagination*: PaginationSettings
      ## Pagination settings for the blog index
    feed*: FeedSettings
      ## Feed-related settings for StupidGreen
    activitypub*: ActivityPubSettings
      ## ActivityPub federated mode settings
    navbar*: Option[seq[StupidGreenNavItem]]
      ## Top navigation bar configuration
    footer*: StupidGreenFooter
      ## Footer configuration

var
  enableBrowserSync* = true
    ## Whether to enable BrowserSync for live-reloading during writing

  stupidGreenProjectPath*: string
    ## The absolute path to the current StupidGreen project

  globalStupidGreenConfig*: StupidGreenConfig
    ## Global variable to hold the StupidGreen configuration loaded from the config file.

proc isAbsoluteUrl*(url: string): bool =
  ## Whether a URL is absolute (has a scheme), protocol-relative, or a fragment
  ## (e.g. `https://...`, `mailto:...`, `//cdn.example.com`, `#section`)
  url.startsWith("http://") or url.startsWith("https://") or
  url.startsWith("//") or url.startsWith("#") or
  url.startsWith("mailto:") or url.startsWith("tel:") or
  url.startsWith("javascript:") or url.startsWith("data:")

proc ensureLeadingSlash*(config: StupidGreenConfig) =
  ## Ensures that relative URLs start with a leading slash.
  ## Absolute URLs (e.g. `https://github.com/example`) are left untouched.
  for navItem in config.navbar.get(@[]):
    if navItem.url.len > 0 and navItem.url[0] != '/' and not isAbsoluteUrl(navItem.url):
      navItem.url.insert("/", 0)
  for link in config.footer.links.get(@[]):
    if link.url.len > 0 and link.url[0] != '/' and not isAbsoluteUrl(link.url):
      link.url.insert("/", 0)
