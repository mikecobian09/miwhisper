#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI_PATH="${CLI_PATH:-$ROOT_DIR/vendors/whisper.cpp/build/bin/whisper-cli}"
MODEL_PATH="${MODEL_PATH:-$ROOT_DIR/models/ggml-small.bin}"
SAMPLE_PATH="${SAMPLE_PATH:-$ROOT_DIR/vendors/whisper.cpp/samples/jfk.wav}"
OUTPUT_BASE="/tmp/miwhisper-smoke"

"$CLI_PATH" -m "$MODEL_PATH" -f "$SAMPLE_PATH" -l en -nt -np -of "$OUTPUT_BASE" -otxt
cat "$OUTPUT_BASE.txt"
