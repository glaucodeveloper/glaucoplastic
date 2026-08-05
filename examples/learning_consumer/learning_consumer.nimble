version       = "0.1.0"
author        = "GlaucoPlastic"
description   = "Exemplo de aprendizagem/refinamento em background"
license       = "MIT"
srcDir        = "src"
bin           = @["consumer"]

requires "nim >= 2.0.0"

task prepareDev, "Prepara os diretórios locais":
  exec "nimble run -- --prepare-dev"

task learningDemo, "Executa coleta, aprovação, dataset e worker":
  exec "nimble run -- --learning-demo"
