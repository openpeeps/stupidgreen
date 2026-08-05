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
└── assets/                  # optional `style.css` override
```

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
