#!/usr/bin/env bash
set -Eeuo pipefail

help_text="$("$LLAMA_SERVER" --help 2>&1 || true)"

args=(
  --model "${GEMMA_MODEL:?}"
  --alias "${GEMMA_ALIAS:-gemma-4-e4b}"
  --host "${GEMMA_HOST:-127.0.0.1}"
  --port "${GEMMA_PORT:-19191}"
  --ctx-size "${GEMMA_CONTEXT:-65536}"
  --parallel 1
  --threads "${GEMMA_THREADS:-16}"
  --jinja
  --no-webui
)

# Gemma 4 E4B é iniciado sem Flash Attention para evitar o caminho CUDA
# problemático observado com esse modelo.
if grep -q -- '--flash-attn' <<<"$help_text"; then
  args+=(--flash-attn off)
fi

# Contexto longo: K cache em Q8 e V cache em F16.
# O V cache quantizado exige Flash Attention neste build do llama.cpp.
if grep -q -- '--cache-type-k' <<<"$help_text"; then
  args+=(--cache-type-k q8_0)
fi
if grep -q -- '--cache-type-v' <<<"$help_text"; then
  # No llama.cpp atual, quantizar o V cache exige Flash Attention.
  # Como Gemma 4 permanece com --flash-attn off, o V cache fica em f16.
  args+=(--cache-type-v f16)
fi

# Evita que checkpoints de contexto do Gemma 4 consumam RAM em excesso.
if grep -q -- '--cache-ram' <<<"$help_text"; then
  args+=(--cache-ram 0)
fi
if grep -q -- '--ctx-checkpoints' <<<"$help_text"; then
  args+=(--ctx-checkpoints 1)
fi

# --fit escolhe o offload conforme a VRAM que restou depois do Metis.
# Não fornecemos --n-gpu-layers junto com --fit.
if grep -q -- '--fit' <<<"$help_text"; then
  args+=(--fit on)
else
  args+=(--n-gpu-layers "${GEMMA_FALLBACK_GPU_LAYERS:-12}")
fi

# Mantém o protocolo JSON mais previsível para o RLM.
if grep -q -- '--reasoning' <<<"$help_text"; then
  args+=(--reasoning off)
fi

exec "$LLAMA_SERVER" "${args[@]}"
