import std/[macros, os]

when defined(macosx):
  --passL:"/usr/local/lib/libmonocypher.a"
  --passC:"-I /opt/local/include"
  --passC:"-I /usr/local/include"
  --passC:"-Wno-incompatible-function-pointer-types"
elif defined(linux):
  --passL:"-L/usr/local/lib/lib -L/usr/local/lib -Wl,-rpath,/usr/local/lib/lib -Wl,-rpath,/usr/local/lib -lmonocypher"
  --passC:"-I /usr/include" 

--define:ssl
--deepCopy:on
--mm:arc
--define:webapp # todo supWebApp
--define:supraFileserver
--define:supranimUseGlobalOnRequest

--define:avx2
--passC:"-mavx2"
--passL:"-mavx2"

--define:supraBundleSkipPrefix
  # When defined, this flag tells Supra (Supranim's CLI) to skip prefixing
  # asset keys with the directory name when embedding assets

when defined supranimDebug:
  --define:checkBounds
  --define:assertions
  --define:useMalloc
  --passC:"-fsanitize=address -fno-omit-frame-pointer"
  --passL:"-fsanitize=address"

when not defined release:
  --define:timHotCode
else:
  --define:supranimEmbedConfig
    # Embed Supranim config files (config/*.yml) into the binary at
    # compile time instead of creating a config/ directory at runtime

  const embedAssetsPath {.strdefine.} = ""
  let outputEmbedAssets = getProjectPath().parentDir() / ".cache" / "embed_assets.nim"
  let assetsPath = absolutePath(joinPath(getProjectPath() / "storage", "assets"))
  if dirExists(assetsPath):
    exec "supra bundle.assets \"" & assetsPath & "\" \"" & outputEmbedAssets & "\""

  for dir in ["views", "layouts", "partials"]:
    let outputEmbedTemplates = getProjectPath().parentDir() / ".cache" / "embed_templates_" & dir & ".nim"
    let templatesPath = absolutePath(joinPath(getProjectPath() / "templates" / dir))
    if dirExists(templatesPath):
      exec "supra bundle.assets \"" & templatesPath & "\" \"" & outputEmbedTemplates & "\" --skip-prefix"

  let outputSVGIcons = getProjectPath().parentDir() / ".cache" / "embed_storage_icons.nim"
  let iconsPath = absolutePath(joinPath(getProjectPath() / "storage", "icons"))
  if dirExists(iconsPath):
    exec "supra bundle.assets \"" & iconsPath & "\" \"" & outputSVGIcons & "\""
