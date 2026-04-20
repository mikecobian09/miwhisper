#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR_DIR="$ROOT_DIR/vendors/whisper.cpp"
BUILD_DIR="$VENDOR_DIR/build"
MODEL_DIR="$ROOT_DIR/models"
CMAKE_BIN="${CMAKE_BIN:-$(command -v cmake || true)}"
ARCH_ARGS=()
DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"

if [[ -z "$CMAKE_BIN" ]]; then
  echo "cmake was not found in PATH." >&2
  exit 1
fi

if [[ "$(uname -m)" == "arm64" ]]; then
  CMAKE_FILE_INFO="$(file "$CMAKE_BIN")"

  if [[ "$CMAKE_FILE_INFO" == *"x86_64"* && "$CMAKE_FILE_INFO" != *"arm64"* ]]; then
    if [[ "${ALLOW_TRANSLATED_CMAKE:-0}" != "1" ]]; then
      cat >&2 <<EOF
Refusing to build whisper.cpp with an x86_64-only cmake on Apple Silicon.
This would produce an x86_64 whisper-cli under Rosetta and give misleading latency numbers.

Install an arm64 cmake first, typically under /opt/homebrew/bin/cmake, then rerun:
  CMAKE_BIN=/opt/homebrew/bin/cmake ./scripts/bootstrap-whispercpp.sh

If you explicitly want the Rosetta build anyway, rerun with:
  ALLOW_TRANSLATED_CMAKE=1 ./scripts/bootstrap-whispercpp.sh
EOF
      exit 1
    fi

    echo "Warning: building whisper.cpp with translated x86_64 cmake on Apple Silicon." >&2
  fi
fi

if [[ ! -f "$VENDOR_DIR/CMakeLists.txt" ]]; then
  if [[ -e "$VENDOR_DIR" && ! -d "$VENDOR_DIR" ]]; then
    echo "Vendor path exists but is not a directory: $VENDOR_DIR" >&2
    exit 1
  fi

  if [[ -d "$VENDOR_DIR" ]] && [[ -n "$(find "$VENDOR_DIR" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
    echo "Vendor path exists but does not look like whisper.cpp: $VENDOR_DIR" >&2
    exit 1
  fi

  rm -rf "$VENDOR_DIR"
  git clone --depth 1 https://github.com/ggml-org/whisper.cpp.git "$VENDOR_DIR"
fi

if [[ -n "${CMAKE_OSX_ARCHITECTURES:-}" ]]; then
  ARCH_ARGS+=("-DCMAKE_OSX_ARCHITECTURES=${CMAKE_OSX_ARCHITECTURES}")
fi

cmake_args=(
  -S "$VENDOR_DIR"
  -B "$BUILD_DIR"
  -DBUILD_SHARED_LIBS=OFF
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"
  -DGGML_METAL=ON
  -DGGML_METAL_EMBED_LIBRARY=ON
)

if [[ ${#ARCH_ARGS[@]} -gt 0 ]]; then
  cmake_args+=("${ARCH_ARGS[@]}")
fi

"$CMAKE_BIN" "${cmake_args[@]}"
"$CMAKE_BIN" --build "$BUILD_DIR" --config Release -j

mkdir -p "$MODEL_DIR"

if [[ ! -f "$MODEL_DIR/ggml-small.bin" ]]; then
  "$VENDOR_DIR/models/download-ggml-model.sh" small
  mv "$VENDOR_DIR/models/ggml-small.bin" "$MODEL_DIR/ggml-small.bin"
fi

echo "whisper-cli: $BUILD_DIR/bin/whisper-cli"
echo "model: $MODEL_DIR/ggml-small.bin"
echo "libwhisper: $BUILD_DIR/src/libwhisper.a"
