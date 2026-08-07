# Package
version       = "0.1.8"
author        = "Glauco Developer"
description   = "Framework monolítico Nim para DSL de aplicações, ORM, estados, RLM, Git memory, OKF e WebContents foreign."
license       = "MIT"
srcDir        = "src"

requires "nim >= 2.0.0"

task runtimeLinux, "Baixa o runtime llama.cpp para Linux":
  exec "bash scripts/install-llama-runtime-linux.sh"

task runtimeWindows, "Baixa o runtime llama.cpp no Windows":
  exec "pwsh -File scripts/install-llama-runtime-windows.ps1"

task runtimeWindowsCross, "Prepara o runtime Windows a partir do Linux":
  exec "bash scripts/install-llama-runtime-windows.sh"

task buildWindows, "Cross-compila e empacota o local_assistant Windows x64 a partir do Linux":
  exec "bash scripts/build-windows-cross.sh"

task cleanWindows, "Remove somente artefatos de build Windows; preserva downloads/modelos em dist":
  exec "rm -rf .build/windows-x64/nimcache .build/windows-x64/assistant_consumer_windows.nim dist/windows-x64/assistant_consumer.exe"

task modelLinux, "Configura ou baixa Qwen3-4B GGUF":
  exec "bash scripts/configure-qwen3-model.sh"

task modelWindows, "Configura ou baixa Qwen3-4B GGUF no Windows":
  exec "pwsh -File scripts/configure-qwen3-model.ps1"

task bootstrapLinux, "Instala dependências, runtime e modelo no Linux":
  exec "bash scripts/install-all-linux.sh"

task bootstrapWindows, "Instala dependências, runtime e modelo no Windows":
  exec "pwsh -File scripts/install-all-windows.ps1"

task example, "Compila o exemplo MacroObras":
  exec "nim c -r --path:src examples/macroobras/app.nim"

task test, "Executa testes do plano e runtimes":
  exec "nim c -r -d:glaucoplasticHeadless --path:src tests/test_runtime.nim"

requires "nimpy"
