#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI_PATH="${CLI_PATH:-$ROOT_DIR/vendors/whisper.cpp/build/bin/whisper-cli}"

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <audio.wav> <model1> [model2 ...]" >&2
  echo "Example: $0 /tmp/test.wav small medium large-v3-turbo-q5_0" >&2
  exit 1
fi

AUDIO_PATH="$1"
shift

if [[ ! -f "$AUDIO_PATH" ]]; then
  echo "Missing audio file: $AUDIO_PATH" >&2
  exit 1
fi

if [[ ! -x "$CLI_PATH" ]]; then
  echo "Missing whisper-cli at $CLI_PATH. Run ./scripts/bootstrap-whispercpp.sh first." >&2
  exit 1
fi

for model in "$@"; do
  MODEL_PATH="$ROOT_DIR/models/ggml-$model.bin"
  if [[ ! -f "$MODEL_PATH" ]]; then
    echo "Missing model $MODEL_PATH. Download it with ./scripts/download-model.sh $model" >&2
    exit 1
  fi

  echo
  echo "== $model =="
  /usr/bin/time -p "$CLI_PATH" \
    -m "$MODEL_PATH" \
    -f "$AUDIO_PATH" \
    -l es \
    -nt \
    -np \
    -otxt \
    -of /tmp/miwhisper-bench >/dev/null
done
