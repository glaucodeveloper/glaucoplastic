# Continuação da instalação

O Qwen3-4B já pode permanecer em:

```text
~/models/Qwen3-4B/Qwen3-4B-Q4_K_M.gguf
```

Os binários do llama.cpp serão baixados para:

```text
runtime/llama/linux-x64/bin/
runtime/llama/windows-x64/bin/
```

## Linux com NVIDIA

Use o backend Vulkan para obter um runtime binário pronto:

```bash
chmod +x scripts/*.sh

./scripts/configure-qwen3-model.sh
LLAMA_BACKEND=vulkan ./scripts/install-llama-runtime-linux.sh

nimble develop -y
nimble test
```

O script do modelo detecta o arquivo já existente e não o baixa novamente.

## Verificação

```bash
ls -lh runtime/llama/linux-x64/bin/llama-server
ls -lh ~/models/Qwen3-4B/Qwen3-4B-Q4_K_M.gguf

runtime/llama/linux-x64/bin/llama-server --version
```

## Configuração explícita opcional

```bash
export GLAUCOPLASTIC_LLAMA_BIN="$PWD/runtime/llama/linux-x64/bin/llama-server"
export GLAUCOPLASTIC_MODEL_PATH="$HOME/models/Qwen3-4B/Qwen3-4B-Q4_K_M.gguf"
export GLAUCOPLASTIC_MODEL_ALIAS="qwen3-4b"

nimble test
```
