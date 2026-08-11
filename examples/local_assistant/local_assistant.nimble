version       = "0.2.0"
author        = "Ícaro"
description   = "Assistente local White Plastic com voz, Markdown, memória e ferramentas de escritório."
license       = "MIT"

srcDir = "."
binDir = "bin"
bin    = @["assistant_consumer"]

requires "nim >= 2.2.0"

task clean, "Remove artefatos locais de compilação":
  exec "rm -rf bin nimcache"

# O fluxo de build é implementado pelo próprio GlaucoPlastic.

# GlaucoPlastic local.
# A dependência aponta para a raiz do repo principal.
requires "file://../.."

const glaucoplasticApplication = "assistant_consumer"

include "../../nimble/glaucoplastic_tasks.nims"
