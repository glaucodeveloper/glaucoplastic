# begin Nimble config (version 2)
when withDir(thisDir(), system.fileExists("nimble.paths")):
  include "nimble.paths"
# end Nimble config

import std/os

let nimpyPath =
  getHomeDir() / ".nimble" / "pkgs2" /
    "nimpy-0.2.1-22173fb24ce9ca9d1c1db63fe15bdfb14e69c76a"

if dirExists(nimpyPath):
  switch("path", nimpyPath)
