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

  get "/{slug:anySlug}"
    # A catch-all GET route that will match any path
    # and pass it to the `getSlug` controller for handling
    # the 404 fallback.
