<p align="center">
  StupidGreen &mdash; A fast static blog generator built on top of <a href="https://github.com/supranim/supranim">Supranim</a><br>
  Compiled &bullet; Lightweight &bullet; Fast &bullet; 👑 Written in Nim language
</p>

<p align="center">
  <code>nimble install stupidgreen</code>
</p>

## 😍 Key Features
- 🔥 **Compiled**, extremely **lightweight**, **super fast!**
- Markdown support for writing content with YAML frontmatter
- Blog capabilities with support for **tags** and **categories**
- Support for pages and nested structure (`pages/projects/x.md` to `/projects/x`)
- **RSS/Atom feed** + **sitemap.xml** + **llms.txt** generation
- Lazy loading of iframes, images and other media
- Search functionality with support for fuzzy search and search suggestions
- **`/llms.txt`** from `pages/llms.md` (LLM-friendly plain text)
- **Reading time** & body-derived **excerpts** with "Continue reading" links
- **OpenGraph Image generation** for social media sharing
- Easy to extend with custom **CSS** and **JS**

## About
StupidGreen is a static blog generator written in [Nim](https://nim-lang.org). It takes a
directory of Markdown files and generates a fully static website, powered by [Supranim](https://supranim.com),
[Tim Engine](https://github.com/openpeeps/tim), [Marvdown](https://github.com/openpeeps/marvdown) and [Boogie](https://github.com/openpeeps/boogie).

## 🚀 Getting Started

```bash
stupidgreen new my-blog && cd my-blog

stupidgreen post "Hello World"   # create a new post
stupidgreen run --sync           # development server with live reload
stupidgreen build .              # generate the static site into `_build/`
```

## StupidGreen project structure

```
my-blog/
├── stupidgreen.config.yaml      # site configuration
├── posts/                   # blog posts (title, date, tags, draft, ...)
│   ├── index.md             # homepage intro (blog index) when no pages/index.md
│   └── hello-world.md
├── pages/                   # standalone pages, mapped to their URL path
│   ├── index.md             # homepage intro, rendered above the post list
│   ├── about.md             # /about
│   ├── llms.md              # /llms.txt (plain text)
│   └── projects/
│       ├── index.md         # /projects
│       └── demo.md          # /projects/demo
├── assets/                  # optional `style.css` override
└── themes/                  # Tim themes (see Themes below)
    └── default/             # built-in theme, seeded by `stupidgreen new`
        ├── theme.yaml       # theme manifest (name, version, author, ...)
        ├── layouts/         # page layouts (`base.timl`)
        ├── views/           # page views (`index`, `post`, `page`, `tag`, ...)
        └── partials/        # reusable snippets (`header`, `post-cards`, ...)
```

### Themes
StupidGreen renders pages with [Tim Engine](https://github.com/openpeeps/tim)
templates organized into themes. Every project has a `themes/` directory; the
active theme is selected with the top-level `theme` key in
`stupidgreen.config.yaml` (defaults to `"default"`):

```yaml
theme: "my-theme"
```

Each theme lives in `themes/<name>/` and starts with a `theme.yaml` manifest:

```yaml
name: "my-theme"
version: "0.1.0"
author: "Jane Doe"
url: "https://example.com/my-theme"
license: "MIT"
description: "A minimal theme that only restyles the homepage"
```

Views go in `views/`, layouts in `layouts/`, reusable snippets in `partials/`.
The built-in `default` theme provides `layouts/base.timl`,
`views/{index,post,page,tag,category,search}.timl` (plus `views/errors/`)
and `partials/{header,post-cards,pagination}.timl`.

A theme may override only the templates it cares about: anything missing
from the active theme falls back to the built-in `default` theme at render
time. This applies to views, layouts and `@include`d partials alike, so a
one-file theme is fully functional.

#### Example 1 — restyle the homepage
Create a theme that only replaces the blog index. Every other page keeps
rendering from `default`:

```
themes/minimal/
├── theme.yaml
└── views/index.timl
```

```timl
@include "header"
div.container.my-5
  h1.display-4: $this["config"]["metadata"]["title"]
  p.lead: $this["config"]["metadata"]["description"]
  if $this["intro"] != "":
    article: $this["intro"]
  @include "post-cards"
  @include "pagination"
```

```yaml
# stupidgreen.config.yaml
theme: "minimal"
```

```bash
stupidgreen build .   # index.html uses minimal, posts/pages use default
```

The `@include "header"` / `@include "post-cards"` lines above resolve to
`minimal/partials/` first and fall back to `default/partials/` when the
minimal theme doesn't ship them.

#### Example 2 — override a partial
Partials are shared snippets, so overriding one affects every view that
includes it. To render your own post cards, copy the original as a starting
point and edit it:

```bash
mkdir -p themes/minimal/partials
cp themes/default/partials/post-cards.timl themes/minimal/partials/
```

```timl
# themes/minimal/partials/post-cards.timl
div.post-list
  for $post in items($this["posts"]):
    article.mb-4
      h2.h5: $post["meta"]["title"]
      a href=$post["url"]: "Read more →"
```

#### Example 3 — full custom layout
Override `layouts/base.timl` to take over the whole HTML shell (head, CSS,
navbar, footer). Views stay compatible as long as the layout renders the
view output where `base.timl` does:

```bash
mkdir -p themes/minimal/layouts
cp themes/default/layouts/base.timl themes/minimal/layouts/
```

#### Notes
- Missing `themes/default/` files are seeded automatically on `new`,
  `start` and `build` without overwriting your customizations, so old
  projects upgrade themselves on first run.
- An unknown theme name fails fast and lists the available themes, e.g.
  `Active theme not found: nope. Available themes: minimal, default`.
- In development (`start --sync`) theme files hot-reload in the browser.

### Post front matter

```markdown
---
title: "Hello World"
date: 2026-01-15
tags: [nim, blogging]
categories: [tutorial]
author: "George Lemon"
excerpt: "Optional custom excerpt"  # overrides the auto-generated one
cover: "/assets/cover.jpg"
draft: false
---
```

### Pages
Any `.md` file in `pages/` becomes a standalone page at its path. `index.md` is
reserved for the *first page* of a directory (`pages/projects/index.md` → `/projects`).
The homepage always renders the blog index (`index.timl`): it shows the intro from
`pages/index.md` (or `posts/index.md`) above the list of post cards.

> Note: page files under reserved route paths (`/posts/*`, `/page/*`, `/tags/*`,
> `/categories/*`, `/search`, `/feed.xml`, `/sitemap.xml`, `/llms.txt`) are
> shadowed by those routes.

### Configuration
`stupidgreen.config.yaml` supports metadata (title, description, url, author),
appearance (theme, container widths), header (search, notification), content
(reading time, excerpt length, read-more label, lazyload), pagination (`per_page`),
feed (kind `rss`/`atom`, limit) and navbar/footer links.

### ❤ Contributions & Support
- 🐛 Found a bug? [Create a new Issue](https://github.com/openpeeps/stupidgreen/issues)
- 👋 Wanna help? [Fork it!](https://github.com/openpeeps/stupidgreen/fork)
- 🎉 Spread the word! **Tell your friends about StupidGreen**

|  |  |
|---|---|
| <a href="https://opencode.ai/go?ref=BHMEEK48QX"><img src="https://github.com/openpeeps/pistachio/blob/main/.github/opencode.png" alt="OpenCode"></a> | Switch to **Open-Source LLMs** via OpenCode GO, choosing from a variety of powerful models such as DeepSeek, Qwen, Kimi, GLM-5, MiniMax, MiMo. 🍕 [Use our referral link to get started!](https://opencode.ai/go?ref=BHMEEK48QX)|

### 🎩 License
StupidGreen | `AGPLv3` license. [Made by Humans from OpenPeeps](https://github.com/openpeeps).<br>
Copyright &copy; 2026 OpenPeeps & Contributors &mdash; All rights reserved.
