# StupidGreen - A static blog generator for cool kids!
#
# (c) 2026 George Lemon | AGPL-3.0-or-later License
#          Made by Humans from OpenPeeps

## ActivityPub federation support for StupidGreen.
##
## Turns the blog into a Fediverse account (`@username@domain`) that other
## federated platforms (Mastodon, Lemmy, etc.) can follow. New posts are pushed
## to followers' inboxes as `Create(Article)` activities; edits send `Update`;
## deletions (and the `draft: true` flip) send `Delete`.
##
## The actor is served from the StupidGreen HTTP server (see `stupidgreen.nim`),
## exposing WebFinger, the actor profile, inbox, outbox, followers and following
## collections. The actor's Ed25519 keypair, the followers list and the outbox
## are persisted in a Boogie document store.
##
## The inbox auto-accepts `Follow` activities (storing the follower and
## delivering an `Accept`) and handles `Undo(Follow)` to unfollow. Other inbound
## activities are silently ignored.

import std/[os, uri, strutils, options, tables]

import pkg/[activitypub, boogie/stores/docstore]
import pkg/activitypub/datatypes/metatypes
import pkg/openparser/json
import pkg/threading/rwlock

import ../../app/structs

export structs

const
  apPublicCollection = "https://www.w3.org/ns/activitystreams#Public"

type
  Follower* = object
    ## A remote actor that follows the blog
    actorUrl*: string
    inbox*: string
    sharedInbox*: string

  ActorRecord* = object
    ## Persisted actor keypair
    privateKeyHex*: string
    publicKeyPem*: string

  FollowerList* = object
    ## Persisted followers list
    items*: seq[Follower]

var
  apSettings: ActivityPubSettings
  apBaseUrl*: string
  apDomain*: string
  apUsername*: string
  apActorId*: string
  apKeyId*: string
  apInboxUrl*: string
  apOutboxUrl*: string
  apFollowersUrl*: string
  apFollowingUrl*: string
  apActorJson: JsonNode
  apPrivateKeyHex: string
  apDispatcher*: InboxDispatcher
  apStore*: ActivityStore
  apLocker = createRwLock()
  apPersist: DocumentStore
  followers: seq[Follower]
  outbox: seq[JsonNode]
  apInitialized = false

proc onFollow(f: Follow, verifiedBy: string): InboxResult
proc onUndo(u: Undo, verifiedBy: string): InboxResult
proc removePost*(url: string)

proc apIconUrl(): string =
  ## Returns the absolute actor avatar URL (config values may be relative)
  if apSettings.icon.len == 0:
    return ""
  if apSettings.icon[0] == '/':
    apBaseUrl & apSettings.icon
  else:
    apSettings.icon

proc buildActorJson(publicKeyPem: string): JsonNode =
  ## Builds the ActivityPub actor document for the blog
  result = %*{
    "@context": [
      "https://www.w3.org/ns/activitystreams",
      "https://w3id.org/security/v1"
    ],
    "id": apActorId,
    "type": "Person",
    "preferredUsername": apUsername,
    "name": (if apSettings.name.len > 0: apSettings.name else: apUsername),
    "summary": apSettings.summary,
    "url": apBaseUrl,
    "inbox": apInboxUrl,
    "outbox": apOutboxUrl,
    "followers": apFollowersUrl,
    "following": apFollowingUrl,
    "publicKey": {
      "id": apKeyId,
      "owner": apActorId,
      "publicKeyPem": publicKeyPem
    }
  }
  let iconUrl = apIconUrl()
  if iconUrl.len > 0:
    result["icon"] = %*{"type": "Image", "mediaType": "image/png", "url": iconUrl}

proc initActivityPub*(projectPath, baseUrl: string, settings: ActivityPubSettings) =
  ## Initializes the ActivityPub service: opens the persistence store, loads
  ## (or generates) the actor keypair, and loads followers + outbox. A no-op
  ## when `settings.enable` is false.
  if not settings.enable:
    return
  apSettings = settings
  apBaseUrl = baseUrl
  apDomain = parseUri(baseUrl).hostname
  apUsername = settings.username
  apActorId = baseUrl & "/users/" & apUsername
  apKeyId = apActorId & "#main-key"
  apInboxUrl = apActorId & "/inbox"
  apOutboxUrl = apActorId & "/outbox"
  apFollowersUrl = apActorId & "/followers"
  apFollowingUrl = apActorId & "/following"

  # reset in-memory state (re-init is idempotent)
  apStore = newActivityStore()
  followers = @[]
  outbox = @[]
  apInitialized = false

  let storeDir = projectPath / "storage" / "stupidgreen-activitypub"
  createDir(storeDir)
  apPersist = openDocumentStore(storeDir, "activitypub",
    defaultEncoding = deJson,
    checkpointEveryOps = 50,
    walFlushEveryOps = 50
  )

  # load or generate the actor's Ed25519 keypair (must stay stable across restarts)
  var privateKeyHex = ""
  var publicKeyPem = ""
  if apPersist.hasKey("actor"):
    try:
      let rec = fromJson(toJson(apPersist.get("actor").get()), ActorRecord)
      privateKeyHex = rec.privateKeyHex
      publicKeyPem = rec.publicKeyPem
    except:
      discard
  if privateKeyHex.len == 0:
    (publicKeyPem, privateKeyHex) = generateEd25519KeypairPem()
    apPersist.putObj("actor", ActorRecord(
      privateKeyHex: privateKeyHex, publicKeyPem: publicKeyPem), sync = true)
  apPrivateKeyHex = privateKeyHex

  apActorJson = buildActorJson(publicKeyPem)
  apStore.actors[apUsername] = ActorData(
    json: apActorJson,
    username: apUsername,
    privateKeyHex: privateKeyHex,
    publicKeyPem: publicKeyPem
  )

  # load persisted followers + outbox
  if apPersist.hasKey("followers"):
    try:
      followers = fromJson(toJson(apPersist.get("followers").get()), FollowerList).items
    except:
      followers = @[]
  if apPersist.hasKey("outbox"):
    try:
      let node = apPersist.get("outbox").get()
      for item in node{"items"}:
        outbox.add(item)
    except:
      outbox = @[]
  apPersist.checkpoint()

  apDispatcher = newDispatcher(proc (keyId: string): JsonNode =
    try:
      # known local actor (used during tests and for our own key)
      apStore.findActorByKeyId(keyId).json
    except:
      # remote sender: fetch the actor document by its keyId URL
      # (keyId is `<actorUrl>#main-key`) to resolve its public key
      try:
        fetchObject(keyId.split('#')[0])
      except:
        nil
  )
  register[Follow](apDispatcher, "Follow", onFollow)
  register[Undo](apDispatcher, "Undo", onUndo)
  apInitialized = true

proc apEnabled*(): bool =
  ## Whether the ActivityPub service is active
  apInitialized

proc getFollowers*(): seq[Follower] =
  ## Returns a snapshot of the current followers
  readWith apLocker:
    result = followers

proc getOutbox*(): seq[JsonNode] =
  ## Returns a snapshot of the outbox activities
  readWith apLocker:
    result = outbox

proc persistFollowers() =
  ## Persists the followers list. Caller must hold the write lock.
  apPersist.putObj("followers", FollowerList(items: followers), sync = true)

proc persistOutbox() =
  ## Persists the outbox. Caller must hold the write lock.
  apPersist.putObj("outbox", %*{"items": outbox}, sync = true)

proc onFollow(f: Follow, verifiedBy: string): InboxResult =
  ## Auto-accepts a Follow: stores the follower and delivers an Accept
  let followerUrl = f.actor.get.getStr
  if followerUrl.len == 0:
    return InboxResult(success: false, status: 400, error: "Follow has no actor")
  # resolve the follower's inbox so we can deliver the Accept
  var inboxUrl = ""
  var sharedInboxUrl = ""
  try:
    let ra = resolveRemoteActor(followerUrl)
    inboxUrl = ra.inbox
    sharedInboxUrl = ra.sharedInbox
  except CatchableError:
    discard
  writeWith apLocker:
    var exists = false
    for fl in followers:
      if fl.actorUrl == followerUrl:
        exists = true
        break
    if not exists:
      followers.add(Follower(
        actorUrl: followerUrl,
        inbox: inboxUrl,
        sharedInbox: sharedInboxUrl
      ))
      persistFollowers()
  # deliver the Accept outside the lock (network I/O)
  if inboxUrl.len > 0:
    try:
      let accept = buildAccept(apActorId, f)
      let remote = RemoteActor(id: followerUrl, inbox: inboxUrl,
                               sharedInbox: sharedInboxUrl,
                               publicKey: metatypes.PublicKey(), rawJson: nil)
      discard deliverActivity(remote, apPrivateKeyHex, toJsonNode(accept), apKeyId)
    except CatchableError:
      discard
  InboxResult(success: true, status: 202)

proc onUndo(u: Undo, verifiedBy: string): InboxResult =
  ## Handles Undo(Follow): removes the follower
  if u.`object`.isNone:
    return InboxResult(success: true, status: 202)
  let obj = u.`object`.get
  if obj{"type"}.getStr != "Follow":
    return InboxResult(success: true, status: 202)
  let followerUrl = obj{"actor"}.getStr
  writeWith apLocker:
    var remaining: seq[Follower] = @[]
    for fl in followers:
      if fl.actorUrl != followerUrl:
        remaining.add(fl)
    followers = remaining
    persistFollowers()
  InboxResult(success: true, status: 202)

proc postIsoDate(post: Post): string =
  ## Converts the post date to an ISO 8601 timestamp
  if post.meta.date.len > 0:
    post.meta.date.strip() & "T00:00:00Z"
  else:
    nowIso()

proc buildArticle(post: Post, renderedHtml: string): Article =
  ## Builds an ActivityPub `Article` object from a blog post
  let postUrl = apBaseUrl & post.meta.url
  result = newArticle()
  result.`@context` = some(%* "https://www.w3.org/ns/activitystreams")
  result.id = some(postUrl)
  result.name = some(post.meta.title)
  result.content = some(renderedHtml)
  result.url = some(%* postUrl)
  result.attributedTo = some(%* apActorId)
  result.published = some(postIsoDate(post))
  result.to = some(Addresses(items: @[%* apPublicCollection]))
  result.cc = some(Addresses(items: @[%* apFollowersUrl]))
  var tags: seq[JsonNode] = @[]
  for t in post.meta.tags:
    tags.add(%*{"type": "Hashtag", "name": "#" & t.name})
  if tags.len > 0:
    result.tag = some(tags)

proc deliverToFollowers(activity: JsonNode) =
  ## Delivers an activity to all followers' inboxes. Called outside the lock.
  var targets: seq[RemoteActor] = @[]
  readWith apLocker:
    for fl in followers:
      let inboxUrl = (if fl.sharedInbox.len > 0: fl.sharedInbox else: fl.inbox)
      if inboxUrl.len > 0:
        targets.add(RemoteActor(id: fl.actorUrl, inbox: inboxUrl,
                                sharedInbox: fl.sharedInbox,
                                publicKey: metatypes.PublicKey(), rawJson: nil))
  for target in targets:
    try:
      let result = deliverActivity(target, apPrivateKeyHex, activity, apKeyId)
      if not result.success:
        echo "ActivityPub: delivery to ", target.inbox, " failed: ", result.error
    except CatchableError:
      echo "ActivityPub: delivery error: ", getCurrentExceptionMsg()

proc publishActivity(activity: JsonNode) =
  ## Appends an activity to the outbox and delivers it to followers
  writeWith apLocker:
    outbox.add(activity)
    persistOutbox()
  deliverToFollowers(activity)

proc publishPost*(post: Post, renderedHtml: string, wasPublished: bool) =
  ## Publishes (Create) or updates (Update) a post. `wasPublished` selects
  ## between an `Update` (already federated) and a `Create` (new).
  if not apInitialized or post.meta.draft or post.meta.url == "/":
    return
  let article = buildArticle(post, renderedHtml)
  let activity =
    if wasPublished:
      toJsonNode(buildUpdate(apActorId, article))
    else:
      toJsonNode(buildCreate(apActorId, article,
        to = @[apPublicCollection], cc = @[apFollowersUrl]))
  publishActivity(activity)

proc onPostChanged*(post: Post, renderedHtml: string, wasPublished, nowPublished: bool) =
  ## Reacts to a post change: publishes, updates or deletes based on the
  ## transition between published states.
  if not apInitialized or post.meta.url == "/":
    return
  if wasPublished and nowPublished:
    publishPost(post, renderedHtml, wasPublished = true)
  elif not wasPublished and nowPublished:
    publishPost(post, renderedHtml, wasPublished = false)
  elif wasPublished and not nowPublished:
    removePost(post.meta.url)

proc removePost*(url: string) =
  ## Sends a Delete activity for a post URL (file deletion or unpublishing)
  if not apInitialized or url == "/":
    return
  let activity = toJsonNode(buildDelete(apActorId, apBaseUrl & url))
  publishActivity(activity)

#
# HTTP endpoints (powpow backend only)
#
when defined supraNative:
  import std/httpcore
  import pkg/powpow/proto

  proc apSendJson(res: HttpResponse, body: string) =
    res.status(Http200)
      .header("Content-Type", "application/activity+json")
      .header("Access-Control-Allow-Origin", "*")
      .send(body)

  proc handleWebfinger(req: HttpRequest, res: HttpResponse) =
    var resource = req.getQuery()
    if resource.startsWith("resource="):
      resource = resource[9..^1].replace("%40", "@")
    if resource.len == 0:
      res.sendError(Http400, "Missing resource parameter")
      return
    if resource != "acct:" & apUsername & "@" & apDomain:
      res.sendError(Http404, "Actor not found")
      return
    let jrd = buildJrd(resource, apActorId,
      profilePage = apBaseUrl,
      avatarUrl = apIconUrl())
    res.status(Http200)
      .header("Content-Type", "application/jrd+json")
      .send($jrd)

  proc handleActor(req: HttpRequest, res: HttpResponse) =
    if apActorJson.isNil:
      res.sendError(Http404, "Actor not found")
    else:
      apSendJson(res, $apActorJson)

  proc handleInbox(req: HttpRequest, res: HttpResponse) =
    let body = req.getBodyString()
    var headerList: seq[(string, string)]
    for k, v in req.getHeaders().pairs:
      headerList.add((k, v))
    let inboxPath = "/users/" & apUsername & "/inbox"
    let result = apDispatcher.handle(body, headerList, inboxPath)
    if result.success:
      res.status(Http202).send()
    else:
      let code = case result.status
        of 400: Http400
        of 401: Http401
        else: Http500
      res.sendError(code, result.error)

  proc serveCollection(res: HttpResponse, collectionId: string, items: seq[JsonNode]) =
    var json = %*{
      "@context": "https://www.w3.org/ns/activitystreams",
      "id": collectionId,
      "type": "OrderedCollection",
      "totalItems": items.len,
      "first": collectionId & "?page=1"
    }
    if items.len > 0:
      json["orderedItems"] = %*items
    apSendJson(res, $json)

  proc handleOutbox(req: HttpRequest, res: HttpResponse) =
    readWith apLocker:
      serveCollection(res, apOutboxUrl, outbox)

  proc handleFollowers(req: HttpRequest, res: HttpResponse) =
    var urls: seq[JsonNode] = @[]
    readWith apLocker:
      for fl in followers:
        urls.add(%* fl.actorUrl)
    serveCollection(res, apFollowersUrl, urls)

  proc handleFollowing(req: HttpRequest, res: HttpResponse) =
    serveCollection(res, apFollowingUrl, @[])

  proc apPaths*(): seq[string] =
    ## The exact HTTP paths served by the ActivityPub endpoints
    @[
      "/.well-known/webfinger",
      "/users/" & apUsername,
      "/users/" & apUsername & "/inbox",
      "/users/" & apUsername & "/outbox",
      "/users/" & apUsername & "/followers",
      "/users/" & apUsername & "/following"
    ]

  proc apRoute*(req: HttpRequest, res: HttpResponse) =
    ## Low-level route dispatcher for the ActivityPub endpoints
    let path = req.getPath()
    let actorPath = "/users/" & apUsername
    if path == "/.well-known/webfinger":
      if req.getMethod() == HttpGet:
        handleWebfinger(req, res)
      else:
        res.sendError(Http405, "Method Not Allowed")
    elif path == actorPath:
      if req.getMethod() == HttpGet:
        handleActor(req, res)
      else:
        res.sendError(Http405, "Method Not Allowed")
    elif path == actorPath & "/inbox":
      if req.getMethod() == HttpPost:
        handleInbox(req, res)
      else:
        res.sendError(Http405, "Method Not Allowed")
    elif path == actorPath & "/outbox":
      if req.getMethod() == HttpGet:
        handleOutbox(req, res)
      else:
        res.sendError(Http405, "Method Not Allowed")
    elif path == actorPath & "/followers":
      if req.getMethod() == HttpGet:
        handleFollowers(req, res)
      else:
        res.sendError(Http405, "Method Not Allowed")
    elif path == actorPath & "/following":
      if req.getMethod() == HttpGet:
        handleFollowing(req, res)
      else:
        res.sendError(Http405, "Method Not Allowed")
    else:
      res.sendError(Http404, "Not Found")
