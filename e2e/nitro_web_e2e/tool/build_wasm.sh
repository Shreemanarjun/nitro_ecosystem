#!/usr/bin/env bash
# Builds the web_echo WASM module for the browser e2e test.
# Requires the Emscripten SDK on PATH (emcc/em++), e.g.:
#   source ~/emsdk/emsdk_env.sh
set -euo pipefail

cd "$(dirname "$0")/.."
NITRO_NATIVE="../../packages/nitro/src/native"
GEN="lib/src/generated/cpp"
OUT="web_assets"

mkdir -p "$OUT"

# -fwasm-exceptions: the bridge's try/catch → NitroError contract requires
# C++ exceptions (Emscripten disables them by default). Native wasm EH is
# supported by all current browsers and is cheaper than the JS-based -fexceptions.
em++ -O2 --no-entry -fwasm-exceptions \
  -I"$NITRO_NATIVE" -I"$GEN" \
  "$GEN/web_echo.bridge.g.cpp" src/web_echo_impl.cpp \
  -sMODULARIZE=1 -sEXPORT_NAME=createWebEchoModule \
  -sALLOW_MEMORY_GROWTH=1 -sALLOW_TABLE_GROWTH=1 \
  -sWASM_BIGINT=1 -sENVIRONMENT=web \
  -sEXPORTED_RUNTIME_METHODS=addFunction,removeFunction,wasmExports,wasmMemory,HEAPU8 \
  -sEXPORTED_FUNCTIONS=_malloc,_free \
  -o "$OUT/web_echo.js"

echo "built $OUT/web_echo.js + $OUT/web_echo.wasm"
