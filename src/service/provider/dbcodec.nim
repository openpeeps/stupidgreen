# StupidGreen - A static blog generator for cool kids!
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps

## Custom FBE binary codecs for the on-disk cache (`stupidgreen.db`),
## built on `pkg/openparser/fbe`.
##
## FBE's high-level `encode` only supports plain scalars, so every
## composite StupidGreen type (tables, options, `Post`, `PostMeta`, ...)
## gets an explicit field-id codec below. Field ids are stable; unknown
## ids are skipped on decode, so newer writers stay forward compatible
## with older readers.
##
## Every `.db` file is wrapped in a small signature envelope
## (see `writeDbFile` / `readDbFile`):
##   magic "STUPIDGREEN1" | codec version (u32) | stupidgreen version (string)
##   | payload length (u32) | FBE payload bytes
## A magic or version mismatch means the file is stale or foreign, and
## the caller must rebuild from scratch via rescan (the DB is a cache).

import std/[options, tables, sequtils]
import pkg/openparser/[fbe, json]
import ../../app/structs

export fbe.Buffer, fbe.initBuffer

const
  DbMagic* = "STUPIDGREEN1"
    ## File signature written at the start of every `.db` file
  DbCodecVersion*: uint32 = 2
    ## Version of the codec layout below. Bump when field ids or the
    ## envelope format change in an incompatible way.
  StupidGreenDbVersion* = "0.1.0"
    ## StupidGreen release that wrote the file. Must match the `version`
    ## in `stupidgreen.nimble`; a mismatch invalidates the cache.
    ## Keep in sync manually when releasing.

type
  DbReadStatus* = enum
    ## Outcome of `readDbFile`
    dbOk                ## valid envelope, payload ready in `payload`
    dbMissing           ## file does not exist (first run)
    dbInvalid           ## unreadable envelope or corrupt payload framing
    dbCodecMismatch     ## written by an incompatible codec version
    dbVersionMismatch   ## written by a different StupidGreen release

# ---------------------------------------------------------------------------
# Buffer <-> file helpers
# ---------------------------------------------------------------------------

proc bufferToString*(b: Buffer): string =
  ## Copies raw buffer bytes into a string for `writeFile`
  let n = b.data.len
  result = newStringOfCap(n)
  result.setLen(n)
  if n > 0:
    copyMem(cast[ptr uint8](addr result[0]), unsafeAddr b.data[0], n)

proc stringToBuffer*(s: string): Buffer =
  ## Wraps file bytes into a fresh read buffer (`pos = 0`)
  let n = s.len
  result.data = newSeq[uint8](n)
  if n > 0:
    copyMem(addr result.data[0], cast[ptr uint8](unsafeAddr s[0]), n)
  result.pos = 0

# ---------------------------------------------------------------------------
# Signature envelope
# ---------------------------------------------------------------------------

proc writeDbFile*(path: string, payload: Buffer) =
  ## Writes `payload` to `path` wrapped in the signature envelope
  var b = initBuffer(payload.data.len + 64)
  b.writeString(DbMagic)
  b.writeUint32LE(DbCodecVersion)
  b.writeString(StupidGreenDbVersion)
  b.writeBytes(payload.data)
  writeFile(path, bufferToString(b))

proc readDbFile*(path: string, payload: var Buffer): DbReadStatus =
  ## Reads `path`, validates the signature envelope and returns the raw
  ## FBE payload in `payload` (`pos = 0`). Anything but `dbOk` means the
  ## caller must rebuild the cache from scratch.
  var s: string
  try:
    s = readFile(path)
  except IOError:
    return dbMissing
  except CatchableError:
    return dbInvalid
  var b = stringToBuffer(s)
  try:
    if b.readString() != DbMagic:
      return dbInvalid
    if b.readUint32LE() != DbCodecVersion:
      return dbCodecMismatch
    if b.readString() != StupidGreenDbVersion:
      return dbVersionMismatch
    payload = stringToBuffer(cast[string](b.readBytes()))
  except CatchableError:
    return dbInvalid
  dbOk

# ---------------------------------------------------------------------------
# Tag (used for both tags and categories)
# ---------------------------------------------------------------------------

proc writeTagFields(b: var Buffer, t: Tag) =
  b.writeField(1'u16, proc (bb: var Buffer) = bb.writeString(t.name))
  b.writeField(2'u16, proc (bb: var Buffer) = bb.writeString(t.slug))

proc handleTagField(fid: uint16, fsz: int, b: var Buffer, into: var Tag) =
  case fid
  of 1'u16: into.name = b.readString()
  of 2'u16: into.slug = b.readString()
  else: discard

proc writeTag*(b: var Buffer, t: Tag) =
  b.beginInnerStruct(DbCodecVersion)
  writeTagFields(b, t)
  b.endInnerStruct()

proc readTag*(b: var Buffer): Tag =
  var outVer: uint32
  b.decodeInnerInto(result, handleTagField, outVer)

proc writeTagSeq*(b: var Buffer, items: seq[Tag]) =
  writeVector[Tag](b, items,
    proc (bb: var Buffer, t: Tag) = bb.writeTag(t))

proc readTagSeq*(b: var Buffer): seq[Tag] =
  readVector[Tag](b,
    proc (bb: var Buffer): Tag = bb.readTag())

# ---------------------------------------------------------------------------
# Heading (TOC entry)
# ---------------------------------------------------------------------------

proc writeHeadingFields(b: var Buffer, h: Heading) =
  b.writeField(1'u16, proc (bb: var Buffer) = bb.writeString(h.id))
  b.writeField(2'u16, proc (bb: var Buffer) = bb.writeString(h.title))
  b.writeField(3'u16, proc (bb: var Buffer) = bb.writeInt32LE(int32(h.level)))
  b.writeField(4'u16, proc (bb: var Buffer) = bb.writeString(h.branch))

proc handleHeadingField(fid: uint16, fsz: int, b: var Buffer, into: var Heading) =
  case fid
  of 1'u16: into.id = b.readString()
  of 2'u16: into.title = b.readString()
  of 3'u16: into.level = int(b.readInt32LE())
  of 4'u16: into.branch = b.readString()
  else: discard

proc writeHeading*(b: var Buffer, h: Heading) =
  b.beginInnerStruct(DbCodecVersion)
  writeHeadingFields(b, h)
  b.endInnerStruct()

proc readHeading*(b: var Buffer): Heading =
  var outVer: uint32
  b.decodeInnerInto(result, handleHeadingField, outVer)

proc writeHeadingSeq*(b: var Buffer, items: seq[Heading]) =
  writeVector[Heading](b, items,
    proc (bb: var Buffer, h: Heading) = bb.writeHeading(h))

proc readHeadingSeq*(b: var Buffer): seq[Heading] =
  readVector[Heading](b,
    proc (bb: var Buffer): Heading = bb.readHeading())

# ---------------------------------------------------------------------------
# PostLink / PostNavigation
# ---------------------------------------------------------------------------

proc writePostLinkFields(b: var Buffer, l: PostLink) =
  b.writeField(1'u16, proc (bb: var Buffer) = bb.writeString(l.title))
  b.writeField(2'u16, proc (bb: var Buffer) = bb.writeString(l.url))

proc handlePostLinkField(fid: uint16, fsz: int, b: var Buffer, into: var PostLink) =
  case fid
  of 1'u16: into.title = b.readString()
  of 2'u16: into.url = b.readString()
  else: discard

proc writePostLink*(b: var Buffer, l: PostLink) =
  b.beginInnerStruct(DbCodecVersion)
  writePostLinkFields(b, l)
  b.endInnerStruct()

proc readPostLink*(b: var Buffer): PostLink =
  var outVer: uint32
  b.decodeInnerInto(result, handlePostLinkField, outVer)

proc writeOptPostLink*(b: var Buffer, v: Option[PostLink]) =
  let item = v.get(PostLink())
  writeOptional[PostLink](b, v.isSome, item,
    proc (bb: var Buffer, it: PostLink) = bb.writePostLink(it))

proc readOptPostLink*(b: var Buffer): Option[PostLink] =
  var has = false
  let item = readOptional[PostLink](b,
    proc (bb: var Buffer): PostLink = bb.readPostLink(), has)
  if has: some(item) else: none(PostLink)

proc writePostNavigationFields(b: var Buffer, n: PostNavigation) =
  b.writeField(1'u16, proc (bb: var Buffer) = bb.writeOptPostLink(n.previous))
  b.writeField(2'u16, proc (bb: var Buffer) = bb.writeOptPostLink(n.next))

proc handlePostNavigationField(fid: uint16, fsz: int, b: var Buffer,
                               into: var PostNavigation) =
  case fid
  of 1'u16: into.previous = b.readOptPostLink()
  of 2'u16: into.next = b.readOptPostLink()
  else: discard

proc writePostNavigation*(b: var Buffer, n: PostNavigation) =
  b.beginInnerStruct(DbCodecVersion)
  writePostNavigationFields(b, n)
  b.endInnerStruct()

proc readPostNavigation*(b: var Buffer): PostNavigation =
  var outVer: uint32
  b.decodeInnerInto(result, handlePostNavigationField, outVer)

# ---------------------------------------------------------------------------
# String map (language code -> URL, used for post translations)
# ---------------------------------------------------------------------------

proc writeStringMap*(b: var Buffer, t: Table[string, string]) =
  writeMap[string, string](b, toSeq(pairs(t)),
    proc (bb: var Buffer, k: string) = bb.writeString(k),
    proc (bb: var Buffer, v: string) = bb.writeString(v))

proc readStringMap*(b: var Buffer): Table[string, string] =
  result = initTable[string, string]()
  for kv in readMap[string, string](b,
      proc (bb: var Buffer): string = bb.readString(),
      proc (bb: var Buffer): string = bb.readString()):
    result[kv.key] = kv.val

# ---------------------------------------------------------------------------
# PostMeta
# ---------------------------------------------------------------------------

proc writePostMetaFields(b: var Buffer, m: PostMeta) =
  b.writeField(1'u16, proc (bb: var Buffer) = bb.writeString(m.title))
  b.writeField(2'u16, proc (bb: var Buffer) = bb.writeString(m.date))
  b.writeField(3'u16, proc (bb: var Buffer) = bb.writeInt64LE(m.dateUnix))
  b.writeField(4'u16, proc (bb: var Buffer) = bb.writeString(m.excerpt))
  b.writeField(5'u16, proc (bb: var Buffer) = bb.writeString(m.author))
  b.writeField(6'u16, proc (bb: var Buffer) = bb.writeString(m.cover))
  b.writeField(7'u16, proc (bb: var Buffer) = bb.writeString(m.slug))
  b.writeField(8'u16, proc (bb: var Buffer) = bb.writeString(m.url))
  b.writeField(9'u16, proc (bb: var Buffer) = bb.writeString(m.series))
  b.writeField(10'u16, proc (bb: var Buffer) = bb.writeTagSeq(m.tags))
  b.writeField(11'u16, proc (bb: var Buffer) = bb.writeTagSeq(m.categories))
  b.writeField(12'u16, proc (bb: var Buffer) = bb.writeBool(m.draft))
  b.writeField(13'u16, proc (bb: var Buffer) = bb.writeString(m.layout))
  b.writeField(14'u16, proc (bb: var Buffer) = bb.writeInt64LE(m.fileMtime))
  b.writeField(15'u16, proc (bb: var Buffer) = bb.writeString(m.filePath))
  b.writeField(16'u16, proc (bb: var Buffer) = bb.writeString(m.lang))
  b.writeField(17'u16, proc (bb: var Buffer) = bb.writeStringMap(m.translations))

proc handlePostMetaField(fid: uint16, fsz: int, b: var Buffer, into: var PostMeta) =
  case fid
  of 1'u16: into.title = b.readString()
  of 2'u16: into.date = b.readString()
  of 3'u16: into.dateUnix = b.readInt64LE()
  of 4'u16: into.excerpt = b.readString()
  of 5'u16: into.author = b.readString()
  of 6'u16: into.cover = b.readString()
  of 7'u16: into.slug = b.readString()
  of 8'u16: into.url = b.readString()
  of 9'u16: into.series = b.readString()
  of 10'u16: into.tags = b.readTagSeq()
  of 11'u16: into.categories = b.readTagSeq()
  of 12'u16: into.draft = b.readBool()
  of 13'u16: into.layout = b.readString()
  of 14'u16: into.fileMtime = b.readInt64LE()
  of 15'u16: into.filePath = b.readString()
  of 16'u16: into.lang = b.readString()
  of 17'u16: into.translations = b.readStringMap()
  else: discard

proc writePostMeta*(b: var Buffer, m: PostMeta) =
  b.beginInnerStruct(DbCodecVersion)
  writePostMetaFields(b, m)
  b.endInnerStruct()

proc readPostMeta*(b: var Buffer): PostMeta =
  var outVer: uint32
  b.decodeInnerInto(result, handlePostMetaField, outVer)

# ---------------------------------------------------------------------------
# Post
# ---------------------------------------------------------------------------

proc writePostFields(b: var Buffer, p: Post) =
  b.writeField(1'u16, proc (bb: var Buffer) = bb.writePostMeta(p.meta))
  b.writeField(2'u16, proc (bb: var Buffer) = bb.writeString(p.content))
  b.writeField(3'u16, proc (bb: var Buffer) = bb.writeString(p.last_updated))
  b.writeField(4'u16, proc (bb: var Buffer) = bb.writeInt32LE(int32(p.reading_time)))
  b.writeField(5'u16, proc (bb: var Buffer) = bb.writeHeadingSeq(p.toc))
  b.writeField(6'u16, proc (bb: var Buffer) = bb.writePostNavigation(p.navigation))

proc handlePostField(fid: uint16, fsz: int, b: var Buffer, into: var Post) =
  case fid
  of 1'u16: into.meta = b.readPostMeta()
  of 2'u16: into.content = b.readString()
  of 3'u16: into.last_updated = b.readString()
  of 4'u16: into.reading_time = int(b.readInt32LE())
  of 5'u16: into.toc = b.readHeadingSeq()
  of 6'u16: into.navigation = b.readPostNavigation()
  else: discard

proc writePost*(b: var Buffer, p: Post) =
  b.beginInnerStruct(DbCodecVersion)
  writePostFields(b, p)
  b.endInnerStruct()

proc readPost*(b: var Buffer): Post =
  var outVer: uint32
  b.decodeInnerInto(result, handlePostField, outVer)

# ---------------------------------------------------------------------------
# Post maps (URL -> Post)
# ---------------------------------------------------------------------------

proc writePostMap*(b: var Buffer, t: TableRef[string, Post]) =
  let items =
    if t.isNil: newSeq[tuple[key: string, val: Post]]()
    else: toSeq(pairs(t))
  writeMap[string, Post](b, items,
    proc (bb: var Buffer, k: string) = bb.writeString(k),
    proc (bb: var Buffer, p: Post) = bb.writePost(p))

proc readPostMap*(b: var Buffer): TableRef[string, Post] =
  result = newTable[string, Post]()
  for kv in readMap[string, Post](b,
      proc (bb: var Buffer): string = bb.readString(),
      proc (bb: var Buffer): Post = bb.readPost()):
    result[kv.key] = kv.val
