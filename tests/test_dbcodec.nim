# Round-trip tests for the FBE database codecs (dbcodec)
import std/[unittest, options, tables, os]
import pkg/openparser/fbe
import pkg/openparser/json
import ../src/service/provider/dbcodec
import ../src/app/structs

suite "dbcodec envelope":
  test "writeDbFile/readDbFile round-trip":
    let envelopePath = getTempDir() / "sg_fbe_test_envelope.db"
    var payload = initBuffer()
    payload.writeString("hello-payload")
    writeDbFile(envelopePath, payload)
    var outPayload: Buffer
    check readDbFile(envelopePath, outPayload) == dbOk
    check outPayload.readString() == "hello-payload"

  test "missing file reports dbMissing":
    var outPayload: Buffer
    check readDbFile(getTempDir() / "sg_fbe_test_nonexistent_xyz.db", outPayload) == dbMissing

  test "foreign bytes report dbInvalid":
    let foreignPath = getTempDir() / "sg_fbe_test_foreign.db"
    writeFile(foreignPath, "this is a legacy boogie-era blob")
    var outPayload: Buffer
    check readDbFile(foreignPath, outPayload) == dbInvalid

  test "wrong stupidgreen version reports dbVersionMismatch":
    let badverPath = getTempDir() / "sg_fbe_test_badver.db"
    var payload = initBuffer()
    payload.writeString("x")
    var b = initBuffer()
    b.writeString(DbMagic)
    b.writeUint32LE(DbCodecVersion)
    b.writeString("0.0.0-fake")
    b.writeBytes(payload.data)
    writeFile(badverPath, bufferToString(b))
    var outPayload: Buffer
    check readDbFile(badverPath, outPayload) == dbVersionMismatch

suite "dbcodec entities":
  test "Post round-trip with all fields":
    var post = Post(
      meta: PostMeta(
        title: "Hello",
        date: "2026-08-04",
        dateUnix: 1785628800,
        excerpt: "First post",
        author: "Tester",
        cover: "/assets/cover.png",
        slug: "hello",
        url: "/posts/hello",
        series: "intro",
        tags: @[Tag(name: "nim", slug: "nim")],
        categories: @[Tag(name: "blog", slug: "blog")],
        draft: false,
        layout: "post",
        fileMtime: 1785628801,
        filePath: "/tmp/posts/hello.md"
      ),
      content: "# Hello\n\nBody.",
      last_updated: "2026-08-04 10:00:00",
      reading_time: 3,
      toc: @[Heading(id: "hello", title: "Hello", level: 1, branch: "last")],
      navigation: PostNavigation(
        previous: some(PostLink(title: "Older", url: "/posts/older")),
        next: none(PostLink))
    )
    var b = initBuffer()
    b.writePost(post)
    b.pos = 0
    let back = b.readPost()
    check back.meta.title == "Hello"
    check back.meta.dateUnix == 1785628800
    check back.meta.tags.len == 1
    check back.meta.tags[0].slug == "nim"
    check back.meta.categories[0].name == "blog"
    check back.meta.draft == false
    check back.meta.layout == "post"
    check back.meta.fileMtime == 1785628801
    check back.meta.filePath == "/tmp/posts/hello.md"
    check back.content == "# Hello\n\nBody."
    check back.reading_time == 3
    check back.toc.len == 1
    check back.toc[0].level == 1
    check back.navigation.previous.get().url == "/posts/older"
    check back.navigation.next.isNone

  test "post maps round-trip incl. nil":
    var posts = newTable[string, Post]()
    posts["/posts/a"] = Post(meta: PostMeta(title: "A", url: "/posts/a",
      fileMtime: 10, filePath: "/tmp/a.md"))
    posts["/about"] = Post(meta: PostMeta(title: "About", url: "/about",
      draft: true, fileMtime: 20, filePath: "/tmp/about.md"))
    var b = initBuffer()
    b.writePostMap(posts)
    b.pos = 0
    let back = b.readPostMap()
    check back["/posts/a"].meta.title == "A"
    check back["/about"].meta.draft == true
    check back["/about"].meta.fileMtime == 20
    var b2 = initBuffer()
    b2.writePostMap(nil)
    b2.pos = 0
    check b2.readPostMap().len == 0
