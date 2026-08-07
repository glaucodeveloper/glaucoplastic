#!/usr/bin/env bash
set -Eeuo pipefail

# GLAUCOPLASTIC_DEV_AUTORUN_V1
#
# O dispatcher original continua responsável por compilar/empacotar.
# Este wrapper acrescenta somente o ciclo de execução de desenvolvimento:
#
#   nimble dev / nimble devLinux
#       -> build
#       -> cria bin/<application>
#       -> inicia dist/dev/linux-x64/<application>
#
# Opt-out:
#   GLAUCOPLASTIC_DEV_NO_RUN=1 nimble devLinux


# >>> GLAUCOPLASTIC_METIS_BUILD_BOOTSTRAP_V4 >>>
_GLAUCOPLASTIC_BUILD_SCRIPT_DIR="$(
  cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &&
  pwd
)"

_GLAUCOPLASTIC_METIS_HELPER="$_GLAUCOPLASTIC_BUILD_SCRIPT_DIR/ensure-metis-model.sh"

if [[ -x "$_GLAUCOPLASTIC_METIS_HELPER" ]]; then
  _GLAUCOPLASTIC_METIS_RESOLVED="$(
    bash "$_GLAUCOPLASTIC_METIS_HELPER"
  )" || {
    printf '[GlaucoPlastic] falha ao resolver/baixar IAAR-Shanghai/Metis-4B\n' >&2
    exit 1
  }

  export GLAUCOPLASTIC_METIS_MODEL_PATH="$_GLAUCOPLASTIC_METIS_RESOLVED"

  if [[ "${GLAUCOPLASTIC_BUILD_DEBUG:-0}" == "1" ]]; then
    printf '[GlaucoPlastic] Metis build model: %s\n' \
      "$GLAUCOPLASTIC_METIS_MODEL_PATH" >&2
  fi
fi

unset _GLAUCOPLASTIC_BUILD_SCRIPT_DIR
unset _GLAUCOPLASTIC_METIS_HELPER
unset _GLAUCOPLASTIC_METIS_RESOLVED
# <<< GLAUCOPLASTIC_METIS_BUILD_BOOTSTRAP_V4 <<<

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE="$ROOT/scripts/glaucoplastic-project-build-core.sh"

COMMAND="${1:-}"
APPLICATION="${2:-}"

if [[ -z "$COMMAND" ]]; then
  echo "[glaucoplastic] comando ausente" >&2
  exit 2
fi

if [[ ! -x "$CORE" ]]; then
  echo "[glaucoplastic] dispatcher core ausente: $CORE" >&2
  exit 2
fi

# O Nimble chama o dispatcher a partir da raiz do projeto consumidor.
PROJECT="${GLAUCOPLASTIC_PROJECT_ROOT:-$PWD}"

"$CORE" "$@"

case "$COMMAND" in
  dev|dev-linux)
    ;;
  *)
    exit 0
    ;;
esac

case "${GLAUCOPLASTIC_DEV_NO_RUN:-0}" in
  1|true|TRUE|yes|YES|on|ON)
    echo "[glaucoplastic] dev compilado; autorun desativado"
    exit 0
    ;;
esac

if [[ -z "$APPLICATION" ]]; then
  echo "[glaucoplastic] aplicação ausente para execução dev" >&2
  exit 2
fi

TARGET="$PROJECT/dist/dev/linux-x64/$APPLICATION"

if [[ ! -x "$TARGET" ]]; then
  echo "[glaucoplastic] build terminou, mas executável dev não foi encontrado:" >&2
  echo "  $TARGET" >&2
  exit 2
fi

# Mantém também o caminho tradicional bin/<app>.
mkdir -p "$PROJECT/bin"
ln -sfn \
  "../dist/dev/linux-x64/$APPLICATION" \
  "$PROJECT/bin/$APPLICATION"

echo
echo "[glaucoplastic] iniciando desenvolvimento:"
echo "  $TARGET"
echo

# foreground: Ctrl-C do nimble encerra a aplicação.
cd "$PROJECT"

# GLAUCOPLASTIC_DEV_UI_LOGS_V1
exec "$ROOT/scripts/glaucoplastic-dev-run.sh" "$PROJECT" "$TARGET"
