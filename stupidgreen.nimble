# Package

version       = "0.1.0"
author        = "OpenPeeps"
description   = "A fast static site generator for cool kids!"
license       = "AGPL-3.0-or-later"
srcDir        = "src"
bin           = @["stupidgreen"]
binDir        = "build"

# Dependencies

requires "nim >= 2.0.0"
requires "supranim >= 0.1.9[powpow]"
requires "tim >= 0.2.6"
requires "marvdown >= 0.1.2"
requires "openparser >= 0.1.9"
requires "boogie >= 0.1.1"
requires "watchout >= 0.2.3"
requires "iconim >= 0.1.0"
requires "activitypub >= 0.1.0"

# Supra is not really a dependency but we want to ensure
# it's available when building the release version of StupidGreen
# so we can use Supra's CLI `bundle` command to bundle static assets into the executable.
requires "supra >= 0.1.2"
