switch("threads", "on")
switch("mm", "orc")
switch("nimcache", "nimcache")
switch("path", "../../src")
# begin Nimble config (version 2)
when withDir(thisDir(), system.fileExists("nimble.paths")):
  include "nimble.paths"
# end Nimble config
