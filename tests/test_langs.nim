# StupidGreen language switcher unit tests
#
# Covers the pure language helpers (suffix parsing, URL prefixing and
# config normalization). These run without the StupidGreen binary.
#
# (c) 2026 George Lemon | MIT License

import std/[unittest, tables]

import ../src/app/structs

suite "language config normalization":
  test "disabled by default":
    let config = StupidGreenConfig()
    check not config.languagesEnabled()
    check config.defaultLangCode() == "en"
    check config.supportedLangCodes() == @["en"]

  test "supported codes are lowercased and deduplicated":
    var config = StupidGreenConfig()
    config.languages = LanguageSettings(
      enable: true, default: "EN", supported: @["en", "RO", "ro", ""])
    check config.languagesEnabled()
    check config.defaultLangCode() == "en"
    check config.supportedLangCodes() == @["en", "ro"]

suite "splitLangSuffixRaw":
  const supported = @["en", "ro"]

  test "disabled feature keeps full names, empty lang":
    check splitLangSuffixRaw("/hello-world.ro", false, "en", supported) ==
      ("/hello-world.ro", "", true)
    check splitLangSuffixRaw("/about", false, "en", supported) ==
      ("/about", "", true)

  test "supported suffix splits, default otherwise":
    check splitLangSuffixRaw("/hello-world.ro", true, "en", supported) ==
      ("/hello-world", "ro", true)
    check splitLangSuffixRaw("/hello-world", true, "en", supported) ==
      ("/hello-world", "en", true)
    check splitLangSuffixRaw("/projects/index.ro", true, "en", supported) ==
      ("/projects/index", "ro", true)

  test "suffix matching is case-insensitive":
    check splitLangSuffixRaw("/hello-world.RO", true, "en", supported) ==
      ("/hello-world", "ro", true)

  test "unsupported 2-3 letter codes are rejected":
    check splitLangSuffixRaw("/hello-world.xx", true, "en", supported) ==
      ("", "", false)
    check splitLangSuffixRaw("/hello-world.fra", true, "en", supported) ==
      ("", "", false)

  test "longer dotted names stay default content":
    check splitLangSuffixRaw("/v2.0/post", true, "en", supported) ==
      ("/v2.0/post", "en", true)
    check splitLangSuffixRaw("/my.post", true, "en", supported) ==
      ("/my.post", "en", true)

  test "dotfiles and extensionless names stay default":
    check splitLangSuffixRaw("/.hidden", true, "en", supported) ==
      ("/.hidden", "en", true)
    check splitLangSuffixRaw("about", true, "en", supported) ==
      ("about", "en", true)

suite "prefixUrlFor":
  test "disabled feature passes everything through":
    check prefixUrlFor("ro", "/about", false, "en") == "/about"
    check prefixUrlFor("ro", "/", false, "en") == "/"

  test "default and empty langs pass through":
    check prefixUrlFor("en", "/about", true, "en") == "/about"
    check prefixUrlFor("", "/about", true, "en") == "/about"
    check prefixUrlFor("en", "/", true, "en") == "/"

  test "non-default langs are prefixed":
    check prefixUrlFor("ro", "/about", true, "en") == "/ro/about"
    check prefixUrlFor("ro", "/", true, "en") == "/ro"
    check prefixUrlFor("ro", "/posts/x", true, "en") == "/ro/posts/x"
    check prefixUrlFor("ro", "/page/2", true, "en") == "/ro/page/2"
