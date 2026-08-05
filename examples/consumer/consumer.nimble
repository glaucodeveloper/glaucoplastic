version = "0.3.0"
author = "GlaucoPlastic"
description = "Consumer integral funcional do GlaucoPlastic"
license = "MIT"

srcDir = "src"
bin = @["consumer"]

requires "nim >= 2.0.0"

task dev, "Compila e executa o consumer com ambiente gráfico de desenvolvimento":
  exec "bash scripts/dev.sh"

requires "nimpy"

binDir = "dist/consumer"

# BEGIN GLAUCOPLASTIC METIS STANDARD BUILD
import std/os

let glaucoplasticProjectRoot =
  getEnv(
    "GLAUCOPLASTIC_PROJECT",
    absolutePath(thisDir() / ".." / "..")
  )

before build:
  putEnv("GLAUCOPLASTIC_PROJECT", glaucoplasticProjectRoot)
  putEnv("GLAUCOPLASTIC_CLIENT_DIR", thisDir())
  exec quoteShell(
    glaucoplasticProjectRoot /
      "scripts" /
      "ensure-metis-model.sh"
  )

after build:
  putEnv("GLAUCOPLASTIC_PROJECT", glaucoplasticProjectRoot)
  putEnv("GLAUCOPLASTIC_CLIENT_DIR", thisDir())
  putEnv("GLAUCOPLASTIC_CLIENT_BIN_DIR", binDir)
  exec quoteShell(
    glaucoplasticProjectRoot /
      "scripts" /
      "package-client-with-metis.sh"
  )
# END GLAUCOPLASTIC METIS STANDARD BUILD
