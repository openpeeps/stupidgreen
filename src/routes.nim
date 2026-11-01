#
# This file is automatically imported by the Supranim framework.
# It is used to define the routes for the application.
#

routes:
  get "/"
    # GET route links to `getHomepage` controller

  get "/page/{page:id}"
    # GET route links to `getPage` controller (paginated index)

  get "/posts/{slug:anySlug}"
    # GET route links to `getPost` controller

  get "/tags/{tag:slug}"
    # GET route links to `getTag` controller

  get "/categories/{category:slug}"
    # GET route links to `getCategory` controller

  get "/search"
    # GET route links to `getSearch` controller

  get "/results.json"
    # GET route links to `getResultsJson` controller

  get "/feed.xml"
    # GET route links to `getFeed` controller

  get "/sitemap.xml"
    # GET route links to `getSitemap` controller

  get "/llms.txt"
    # GET route links to `getLlmsTxt` controller

  get "/{lang:alphaSlug}"
    # Language homepage (`/ro`), or a regular page when `lang`
    # is not a supported language (handled by `getLang`)

  get "/{lang:alphaSlug}/page/{page:id}"
    # GET route links to `getLangPagePage` controller (paginated index)

  get "/{lang:alphaSlug}/posts/{slug:anySlug}"
    # GET route links to `getLangPostsSlug` controller

  get "/{lang:alphaSlug}/tags/{tag:slug}"
    # GET route links to `getLangTagsTag` controller

  get "/{lang:alphaSlug}/categories/{category:slug}"
    # GET route links to `getLangCategoriesCategory` controller

  get "/{lang:alphaSlug}/search"
    # GET route links to `getLangSearch` controller

  get "/{lang:alphaSlug}/feed.xml"
    # GET route links to `getLangFeedXml` controller

  get "/{lang:alphaSlug}/llms.txt"
    # GET route links to `getLangLlmsTxt` controller

  get "/{lang:alphaSlug}/{slug:anySlug}"
    # Translated page (`/ro/about`), or a regular nested page when
    # `lang` is not supported (handled by `getLangSlug`)

  get "/{slug:anySlug}"
    # A catch-all GET route that will match any path
    # and pass it to the `getSlug` controller for handling
    # the 404 fallback.
