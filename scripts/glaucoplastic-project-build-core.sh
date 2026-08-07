#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$(pwd -P)"
COMMAND="${1:-}"
APP_NAME="${2:-}"

die() {
  printf '[GlaucoPlastic] ERRO: %s\n' "$*" >&2
  exit 1
}

log() {
  printf '[GlaucoPlastic] %s\n' "$*"
}

prepare_webview2() {
  local env_text
  env_text="$(bash "$ROOT/scripts/prepare-webview2-sdk.sh" --shell-env)"
  eval "$env_text"
}

copy_webview2_loader() {
  local target_dir="$1"
  [[ -n "${GLAUCOPLASTIC_WEBVIEW2_LOADER_DLL:-}" ]] || return 0
  [[ -s "$GLAUCOPLASTIC_WEBVIEW2_LOADER_DLL" ]] || return 0
  mkdir -p "$target_dir"
  cp -f "$GLAUCOPLASTIC_WEBVIEW2_LOADER_DLL" "$target_dir/WebView2Loader.dll"
}

[[ -n "$COMMAND" ]] || die "comando ausente"
[[ -n "$APP_NAME" ]] || die "nome da aplicação ausente"

if [[ -f "$PROJECT/$APP_NAME.nim" ]]; then
  APP_SOURCE="$PROJECT/$APP_NAME.nim"
elif [[ -f "$PROJECT/src/$APP_NAME.nim" ]]; then
  APP_SOURCE="$PROJECT/src/$APP_NAME.nim"
else
  die "fonte não encontrada: $PROJECT/$APP_NAME.nim ou $PROJECT/src/$APP_NAME.nim"
fi

FRAMEWORK_SRC="$ROOT/src"

find_model() {
  local slug="IAAR-Shanghai_Metis-4B"
  local candidates=()

  if [[ -n "${GLAUCOPLASTIC_METIS_MODEL_SOURCE:-}" ]]; then
    candidates+=("$GLAUCOPLASTIC_METIS_MODEL_SOURCE")
  fi

  candidates+=(
    "$ROOT/models/metis/$slug"
    "$ROOT/models/Metis-4B"
    "$PROJECT/models/metis/$slug"
    "$PROJECT/models/Metis-4B"
    "$HOME/.local/share/glaucoplastic/models/metis/$slug"
  )

  local candidate
  for candidate in "${candidates[@]}"; do
    if [[ -s "$candidate/config.json" &&
          -s "$candidate/model.safetensors.index.json" ]]; then
      printf '%s\n' "$(cd "$candidate" && pwd -P)"
      return 0
    fi
  done

  return 1
}

compile_linux() {
  local release="${1:-0}"
  local headless="${2:-0}"
  local web="${3:-0}"

  local mode="dev"
  local output="$PROJECT/dist/dev/linux-x64/$APP_NAME"

  if [[ "$web" == "1" ]]; then
    mode="web"
    output="$PROJECT/dist/web/linux-x64/$APP_NAME"
  elif [[ "$release" == "1" ]]; then
    mode="release"
  fi

  local cache="$PROJECT/.build/$mode/linux-x64/nimcache"
  mkdir -p "$(dirname "$output")" "$cache"

  local args=(
    nim c
    --threads:on
    --mm:orc
    "--path:$FRAMEWORK_SRC"
    "--nimcache:$cache"
    "--out:$output"
  )

  if [[ "$release" == "1" ]]; then
    args+=(-d:release --opt:speed)
  else
    args+=(-d:debug)
  fi

  if [[ "$headless" == "1" ]]; then
    args+=(-d:glaucoplasticHeadless)
  fi

  args+=("$APP_SOURCE")

  log "Linux: $APP_NAME"
  "${args[@]}"
}

compile_windows() {
  local release="${1:-0}"

  command -v x86_64-w64-mingw32-gcc >/dev/null 2>&1 ||
    die "x86_64-w64-mingw32-gcc não encontrado"

  prepare_webview2

  local mode="dev"
  [[ "$release" == "1" ]] && mode="release"

  local output="$PROJECT/dist/dev/windows-x64/$APP_NAME.exe"
  local cache="$PROJECT/.build/$mode/windows-x64/nimcache"

  mkdir -p "$(dirname "$output")" "$cache"

  local args=(
    nim c
    --os:windows
    --cpu:amd64
    --cc:gcc
    --gcc.exe:x86_64-w64-mingw32-gcc
    --gcc.linkerexe:x86_64-w64-mingw32-gcc
    --threads:on
    --mm:orc
    "--path:$FRAMEWORK_SRC"
    "--nimcache:$cache"
    "--out:$output"
  )

  if [[ "$release" == "1" ]]; then
    args+=(-d:release --opt:speed)
  else
    args+=(-d:debug)
  fi

  args+=("$APP_SOURCE")

  log "Windows: $APP_NAME"
  "${args[@]}"
  copy_webview2_loader "$(dirname "$output")"
}

build_linux() {
  local model
  model="$(find_model)" ||
    die "Metis-4B não encontrado"

  local script="$ROOT/scripts/build-linux-complete.sh"
  [[ -x "$script" ]] || die "builder Linux ausente: $script"

  log "Bundle Linux completo"

  GLAUCOPLASTIC_PROJECT="$PROJECT" \
  GLAUCOPLASTIC_APPLICATION="$APP_NAME" \
  GLAUCOPLASTIC_APP_SOURCE="$APP_SOURCE" \
  GLAUCOPLASTIC_METIS_MODEL_SOURCE="$model" \
  GLAUCOPLASTIC_LINUX_DIST="$PROJECT/dist/linux-x64" \
  GLAUCOPLASTIC_LINUX_BUILD="$PROJECT/.build/linux-x64" \
    bash "$script"
}

build_windows() {
  local model
  model="$(find_model)" ||
    die "Metis-4B não encontrado"

  prepare_webview2

  local script="$ROOT/scripts/build-windows-cross.sh"
  [[ -x "$script" ]] || die "builder Windows ausente: $script"

  log "Bundle Windows completo"

  GLAUCOPLASTIC_PROJECT="$PROJECT" \
  GLAUCOPLASTIC_APPLICATION="$APP_NAME" \
  GLAUCOPLASTIC_WINDOWS_APP_SOURCE="$APP_SOURCE" \
  GLAUCOPLASTIC_METIS_MODEL_SOURCE="$model" \
  GLAUCOPLASTIC_WINDOWS_DIST="$PROJECT/dist/windows-x64" \
  GLAUCOPLASTIC_WINDOWS_BUILD="$PROJECT/.build/windows-x64" \
    bash "$script"

  copy_webview2_loader "$PROJECT/dist/windows-x64"
}

verify_target() {
  local target="$1"
  local root="$PROJECT/dist/$target"
  local exe="$root/$APP_NAME"

  [[ "$target" == "windows-x64" ]] && exe="$exe.exe"

  [[ -s "$exe" ]] ||
    die "executável ausente: $exe"

  local model="$root/models/metis/IAAR-Shanghai_Metis-4B"
  [[ -s "$model/config.json" ]] ||
    die "modelo ausente/incompleto: $model"

  if [[ "$target" == "windows-x64" ]]; then
    [[ -s "$root/runtime/metis/python/python.exe" ]] ||
      die "Python Windows ausente"
  else
    [[ -x "$root/runtime/metis/python/bin/python" ]] ||
      die "Python Linux ausente"
  fi

  log "válido: $target"
}

case "$COMMAND" in
  dev-linux)
    compile_linux 0 0 0
    ;;

  dev-windows)
    compile_windows 0
    ;;

  dev)
    compile_linux 0 0 0
    compile_windows 0
    ;;

  build-linux)
    build_linux
    ;;

  build-windows)
    build_windows
    ;;

  build)
    build_linux
    build_windows
    ;;

  web-build)
    compile_linux 1 1 1
    ;;

  web)
    compile_linux 0 1 1
    exec "$PROJECT/dist/web/linux-x64/$APP_NAME" --nw
    ;;

  verify)
    verify_target linux-x64
    verify_target windows-x64
    ;;

  *)
    die "comando desconhecido: $COMMAND"
    ;;
esac
