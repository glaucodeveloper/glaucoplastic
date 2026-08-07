#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${GLAUCOPLASTIC_WEBVIEW2_SDK_VERSION:-1.0.3912.50}"
SDK_ROOT="$ROOT/.build/webview2-sdk/$VERSION"
NUPKG="$SDK_ROOT/Microsoft.Web.WebView2.$VERSION.nupkg"
UNPACK="$SDK_ROOT/package"
INCLUDE="$UNPACK/build/native/include"
LOADER="$UNPACK/build/native/x64/WebView2Loader.dll"
LIB_DIR="$ROOT/.build/webview2/lib"
OBJECT="$LIB_DIR/glaucoplastic_webview2_bridge.o"
STATIC_LIB="$LIB_DIR/libglaucoplastic_webview2.a"
SOURCE="$ROOT/native/windows/glaucoplastic_webview2_bridge.cpp"

die() {
  printf '[GlaucoPlastic][WebView2] ERRO: %s\n' "$*" >&2
  exit 1
}

log() {
  printf '[GlaucoPlastic][WebView2] %s\n' "$*" >&2
}

download_package() {
  mkdir -p "$SDK_ROOT"

  if [[ -s "$NUPKG" ]]; then
    return
  fi

  local url="https://api.nuget.org/v3-flatcontainer/microsoft.web.webview2/${VERSION,,}/microsoft.web.webview2.${VERSION,,}.nupkg"

  log "baixando Microsoft.Web.WebView2 $VERSION"

  python3 - "$url" "$NUPKG" <<'PY'
import pathlib
import sys
import urllib.request

url = sys.argv[1]
target = pathlib.Path(sys.argv[2])
temporary = target.with_suffix(target.suffix + ".partial")

request = urllib.request.Request(
    url,
    headers={"User-Agent": "GlaucoPlastic-WebView2"}
)

with urllib.request.urlopen(request, timeout=120) as response:
    with temporary.open("wb") as output:
        while True:
            chunk = response.read(1024 * 1024)
            if not chunk:
                break
            output.write(chunk)

temporary.replace(target)
PY
}

unpack_package() {
  if [[ -s "$INCLUDE/WebView2.h" && -s "$LOADER" ]]; then
    return
  fi

  rm -rf "$UNPACK"
  mkdir -p "$UNPACK"

  python3 - "$NUPKG" "$UNPACK" <<'PY'
import pathlib
import sys
import zipfile

package = pathlib.Path(sys.argv[1])
target = pathlib.Path(sys.argv[2])

with zipfile.ZipFile(package) as archive:
    archive.extractall(target)
PY

  [[ -s "$INCLUDE/WebView2.h" ]] ||
    die "WebView2.h ausente após extrair o SDK"

  [[ -s "$LOADER" ]] ||
    die "WebView2Loader.dll x64 ausente após extrair o SDK"
}

compile_bridge() {
  command -v x86_64-w64-mingw32-g++ >/dev/null 2>&1 ||
    die "x86_64-w64-mingw32-g++ não encontrado"

  command -v x86_64-w64-mingw32-ar >/dev/null 2>&1 ||
    die "x86_64-w64-mingw32-ar não encontrado"

  [[ -s "$SOURCE" ]] ||
    die "bridge C++ ausente: $SOURCE"

  mkdir -p "$LIB_DIR"

  if [[ -s "$STATIC_LIB" &&
        "$STATIC_LIB" -nt "$SOURCE" &&
        "$STATIC_LIB" -nt "$INCLUDE/WebView2.h" ]]; then
    return
  fi

  log "compilando bridge WebView2 CompositionController"

  x86_64-w64-mingw32-g++ \
    -std=c++17 \
    -O2 \
    -fms-extensions \
    -DUNICODE \
    -D_UNICODE \
    -I"$INCLUDE" \
    -c "$SOURCE" \
    -o "$OBJECT"

  rm -f "$STATIC_LIB"

  x86_64-w64-mingw32-ar \
    rcs \
    "$STATIC_LIB" \
    "$OBJECT"
}

download_package
unpack_package
compile_bridge

case "${1:-}" in
  --shell-env)
    printf 'export GLAUCOPLASTIC_WEBVIEW2_SDK_ROOT=%q\n' "$SDK_ROOT"
    printf 'export GLAUCOPLASTIC_WEBVIEW2_LOADER_DLL=%q\n' "$LOADER"
    printf 'export LIBRARY_PATH=%q\n' "$LIB_DIR${LIBRARY_PATH:+:$LIBRARY_PATH}"
    ;;

  --loader)
    printf '%s\n' "$LOADER"
    ;;

  --lib-dir)
    printf '%s\n' "$LIB_DIR"
    ;;

  *)
    log "SDK: $SDK_ROOT"
    log "bridge: $STATIC_LIB"
    log "loader: $LOADER"
    ;;
esac
