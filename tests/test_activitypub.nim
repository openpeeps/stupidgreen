# StupidGreen ActivityPub service test
#
# Verifies the ActivityPub federation service: actor registration, publishing
# Create(Article) activities to the outbox, auto-accepting a signed Follow
# request, and handling Undo(Follow).
#
# (c) 2026 George Lemon | AGPL-3.0-or-later License

import std/[unittest, json, os, random, strutils, tables, times]

import pkg/activitypub
import pkg/openparser/json

import ../src/service/provider/activitypub as ap
import ../src/app/structs

proc tmpProject(): string =
  result = getTempDir() / "stupidgreen_ap_" & $(getTime().toUnix) & "_" & $rand(9999)
  removeDir(result)

proc initTestService(projectPath: string) =
  ap.initActivityPub(projectPath, "https://stupidgreen.test",
    ActivityPubSettings(
      enable: true,
      username: "blog",
      name: "StupidGreen",
      summary: "A test blog",
      icon: "/assets/stupidgreen.png"
    )
  )
  check(ap.apEnabled())
  check(ap.apActorId == "https://stupidgreen.test/users/blog")

proc samplePost(): Post =
  Post(
    meta: PostMeta(
      title: "Hello, Fediverse",
      url: "/posts/hello",
      date: "2026-08-04",
      excerpt: "First post",
      draft: false
    ),
    content: "# Hello\n\nThis is a post."
  )

suite "ActivityPub service":
  test "initActivityPub registers the blog actor with a stable keypair":
    let dir = tmpProject()
    try:
      initTestService(dir)
      let actorJson = ap.apStore.actors["blog"].json
      check(actorJson{"preferredUsername"}.getStr == "blog")
      check(actorJson{"inbox"}.getStr == "https://stupidgreen.test/users/blog/inbox")
      check(actorJson{"outbox"}.getStr == "https://stupidgreen.test/users/blog/outbox")
      check(actorJson{"publicKey"}{"publicKeyPem"}.getStr.contains("BEGIN PUBLIC KEY"))
      check(ap.apStore.actors["blog"].privateKeyHex.len == 128)
    finally:
      removeDir(dir)

  test "publishing a new post adds a Create(Article) to the outbox":
    let dir = tmpProject()
    try:
      initTestService(dir)
      ap.publishPost(samplePost(), "<h1>Hello</h1><p>This is a post.</p>", wasPublished = false)
      let outbox = ap.getOutbox()
      check(outbox.len == 1)
      check(outbox[0]{"type"}.getStr == "Create")
      check(outbox[0]{"actor"}.getStr == "https://stupidgreen.test/users/blog")
      let obj = outbox[0]{"object"}
      check(obj{"type"}.getStr == "Article")
      check(obj{"name"}.getStr == "Hello, Fediverse")
      check(obj{"url"}.getStr == "https://stupidgreen.test/posts/hello")
      check(obj{"attributedTo"}.getStr == "https://stupidgreen.test/users/blog")
      check(obj{"published"}.getStr == "2026-08-04T00:00:00Z")
      check(obj{"content"}.getStr.contains("<h1>Hello</h1>"))
      check(obj{"to"}[0].getStr == "https://www.w3.org/ns/activitystreams#Public")
      check(obj{"cc"}[0].getStr == "https://stupidgreen.test/users/blog/followers")
    finally:
      removeDir(dir)

  test "editing an existing post adds an Update activity":
    let dir = tmpProject()
    try:
      initTestService(dir)
      ap.publishPost(samplePost(), "<h1>Hello</h1>", wasPublished = true)
      let outbox = ap.getOutbox()
      check(outbox.len == 1)
      check(outbox[0]{"type"}.getStr == "Update")
    finally:
      removeDir(dir)

  test "deleting a post adds a Delete activity":
    let dir = tmpProject()
    try:
      initTestService(dir)
      ap.removePost("/posts/hello")
      let outbox = ap.getOutbox()
      check(outbox.len == 1)
      check(outbox[0]{"type"}.getStr == "Delete")
      check(outbox[0]{"object"}.getStr == "https://stupidgreen.test/posts/hello")
    finally:
      removeDir(dir)

  test "drafts are never federated":
    let dir = tmpProject()
    try:
      initTestService(dir)
      var post = samplePost()
      post.meta.draft = true
      ap.publishPost(post, "<h1>Hello</h1>", wasPublished = false)
      check(ap.getOutbox().len == 0)
    finally:
      removeDir(dir)

  test "auto-accepts a signed Follow and removes it on Undo":
    let dir = tmpProject()
    try:
      initTestService(dir)
      # pre-register the remote follower so the dispatcher can verify
      # its HTTP signature locally (no network)
      let (pubPem, secretHex) = generateEd25519KeypairPem()
      let followerActor = %*{
        "id": "https://social.test/users/alice",
        "inbox": "https://social.test/users/alice/inbox",
        "publicKey": {
          "id": "https://social.test/users/alice#main-key",
          "owner": "https://social.test/users/alice",
          "publicKeyPem": pubPem
        }
      }
      ap.apStore.actors["alice"] = ActorData(
        json: followerActor, username: "alice",
        privateKeyHex: secretHex, publicKeyPem: pubPem)

      let inboxPath = "/users/blog/inbox"
      let follow = buildFollow("https://social.test/users/alice", ap.apActorId)
      let body = $toJsonNode(follow)
      let sig = signRequest("POST", inboxPath, "stupidgreen.test", body,
                            "https://social.test/users/alice#main-key", secretHex)
      let headers = @[
        ("host", "stupidgreen.test"),
        ("date", sig.date),
        ("digest", sig.digest),
        ("signature", sig.signature)
      ]
      let result = ap.apDispatcher.handle(body, headers, inboxPath)
      if not result.success:
        echo "  (debug) inbox Follow failed: ", result.status, " ", result.error
      check(result.success)
      let followers = ap.getFollowers()
      check(followers.len == 1)
      check(followers[0].actorUrl == "https://social.test/users/alice")

      # Undo(Follow) removes the follower
      let undo = buildUndo("https://social.test/users/alice", follow)
      let body2 = $toJsonNode(undo)
      let sig2 = signRequest("POST", inboxPath, "stupidgreen.test", body2,
                             "https://social.test/users/alice#main-key", secretHex)
      let headers2 = @[
        ("host", "stupidgreen.test"),
        ("date", sig2.date),
        ("digest", sig2.digest),
        ("signature", sig2.signature)
      ]
      let r2 = ap.apDispatcher.handle(body2, headers2, inboxPath)
      check(r2.success)
      check(ap.getFollowers().len == 0)
    finally:
      removeDir(dir)

  test "persists state to the boogie store":
    let dir = tmpProject()
    try:
      initTestService(dir)
      ap.publishPost(samplePost(), "<h1>Hello</h1>", wasPublished = false)
      check(ap.getOutbox().len == 1)
      let storeDir = dir / "storage" / "stupidgreen-activitypub"
      check(dirExists(storeDir))
      var files = 0
      for kind, fpath in walkDir(storeDir):
        if kind == pcFile:
          inc files
      check(files > 0)
    finally:
      removeDir(dir)
