version       = "0.2.0"
author        = "Ícaro"
description   = "Assistente local White Plastic com voz, Markdown, memória e ferramentas de escritório."
license       = "MIT"

requires "nim >= 2.2.0"

import std/os

switch("define", "glaucoplasticHeadless")

srcDir = "."
binDir = "bin"
bin    = @["assistant_consumer"]

let LocalRpaRoot = currentSourcePath().parentDir

# Defaults do exemplo. O cliente Nim não precisa mais configurar envs.
putEnv("GLAUCOPLASTIC_LLAMA_HOST", "127.0.0.1")
putEnv("GLAUCOPLASTIC_LLAMA_PORT", "19192")
putEnv("GLAUCOPLASTIC_LLM_ENDPOINT", "http://127.0.0.1:19192/v1")
putEnv("GLAUCOPLASTIC_METIS_MODE", getEnv("GLAUCOPLASTIC_METIS_MODE", "server"))
putEnv(
  "GLAUCOPLASTIC_METIS_ENDPOINT",
  getEnv("GLAUCOPLASTIC_METIS_ENDPOINT", "http://127.0.0.1:19192/v1")
)
putEnv(
  "GLAUCOPLASTIC_METIS_URL",
  getEnv("GLAUCOPLASTIC_METIS_URL", "http://127.0.0.1:19192/v1")
)
putEnv("GLAUCOPLASTIC_MODEL_ALIAS", "IAAR-Shanghai/Metis-4B")
putEnv("GLAUCOPLASTIC_METIS_ENABLED", "1")
putEnv("GLAUCOPLASTIC_METIS_STARTUP", getEnv("GLAUCOPLASTIC_METIS_STARTUP", "1"))
putEnv(
  "GLAUCOPLASTIC_METIS_LOAD_SAFETENSORS_ON_STARTUP",
  getEnv(
    "GLAUCOPLASTIC_METIS_LOAD_SAFETENSORS_ON_STARTUP",
    "1"
  )
)
putEnv(
  "GLAUCOPLASTIC_DISABLE_MODEL_STARTUP",
  getEnv("GLAUCOPLASTIC_DISABLE_MODEL_STARTUP", "0")
)
putEnv("GLAUCOPLASTIC_ASSISTANT_ENABLED", "1")
putEnv("GLAUCOPLASTIC_ASSISTANT_BUILTIN_SHELL", "0")
putEnv("GLAUCOPLASTIC_LLAMA_AUTO_DOWNLOAD_RUNTIME", "0")
putEnv("GLAUCOPLASTIC_LLAMA_AUTO_UPDATE_RUNTIME", "0")
putEnv("GLAUCOPLASTIC_AUTO_DOWNLOAD_MODEL", "0")
putEnv("GLAUCOPLASTIC_VOICE_RECOGNITION", "phone-adb")
putEnv("GLAUCOPLASTIC_RPA_MEMORY_ROOT", LocalRpaRoot / "rpa-memory")
putEnv("GLAUCOPLASTIC_RPA_SCREENSHOT_ROOT", LocalRpaRoot / "rpa-memory" / "screenshots")
putEnv("GLAUCOPLASTIC_RPA_BRIDGE", LocalRpaRoot / "tools" / "glaucoplastic_rpa.py")
putEnv("GLAUCOPLASTIC_RPA_PAUSE", getEnv("GLAUCOPLASTIC_RPA_PAUSE", "0.08"))

when defined(windows):
  putEnv(
    "GLAUCOPLASTIC_RPA_PYTHON",
    getEnv(
      "GLAUCOPLASTIC_RPA_PYTHON",
      LocalRpaRoot / ".venv" / "Scripts" / "python.exe"
    )
  )
  putEnv(
    "GLAUCOPLASTIC_WHISPER_BINARY",
    getEnv(
      "GLAUCOPLASTIC_WHISPER_BINARY",
      LocalRpaRoot / ".runtime" / "whisper.cpp" / "build" / "bin" /
        "Release" / "whisper-cli.exe"
    )
  )
else:
  putEnv(
    "GLAUCOPLASTIC_RPA_PYTHON",
    getEnv(
      "GLAUCOPLASTIC_RPA_PYTHON",
      LocalRpaRoot / ".venv" / "bin" / "python"
    )
  )
  putEnv(
    "GLAUCOPLASTIC_WHISPER_BINARY",
    getEnv(
      "GLAUCOPLASTIC_WHISPER_BINARY",
      LocalRpaRoot / ".runtime" / "whisper.cpp" / "build" / "bin" /
        "whisper-cli"
    )
  )

putEnv(
  "GLAUCOPLASTIC_WHISPER_MODEL",
  getEnv(
    "GLAUCOPLASTIC_WHISPER_MODEL",
    LocalRpaRoot / ".runtime" / "whisper.cpp" / "models" / "ggml-base.bin"
  )
)
putEnv("GLAUCOPLASTIC_FFMPEG_BINARY", getEnv("GLAUCOPLASTIC_FFMPEG_BINARY", "ffmpeg"))

task clean, "Remove artefatos locais de compilação":
  exec "rm -rf bin nimcache"

# O fluxo de build é implementado pelo próprio GlaucoPlastic.

const glaucoplasticApplication = "assistant_consumer"

include "../../nimble/glaucoplastic_tasks.nims"
