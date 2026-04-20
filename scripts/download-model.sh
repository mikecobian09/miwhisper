#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR_DIR="$ROOT_DIR/vendors/whisper.cpp"
MODEL_DIR="$ROOT_DIR/models"

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <model-name>" >&2
  echo "Example: $0 medium" >&2
  echo "Example: $0 large-v3-turbo-q5_0" >&2
  exit 1
fi

if [[ ! -x "$VENDOR_DIR/models/download-ggml-model.sh" ]]; then
  echo "Missing whisper.cpp model downloader. Run ./scripts/bootstrap-whispercpp.sh first." >&2
  exit 1
fi

mkdir -p "$MODEL_DIR"
"$VENDOR_DIR/models/download-ggml-model.sh" "$1" "$MODEL_DIR"
