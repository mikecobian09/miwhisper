# MiWhisper Install Guide for AI Agents

This file is for Codex, ChatGPT, Claude, or any other agent asked to install MiWhisper on a user's Mac.

The goal is not to explain the project. The goal is to get MiWhisper installed and working with the fewest surprises.

## Use This Guide When

- The user asks you to install MiWhisper.
- The user asks you to build MiWhisper locally.
- The user asks you to set up MiWhisper from source.
- The user asks you to verify that MiWhisper works on their machine.

## Important Constraints

- MiWhisper is a macOS app.
- Apple Silicon is strongly preferred.
- The app needs human approval for macOS privacy permissions.
- You can automate the build and app launch, but you cannot silently grant:
  - Microphone
  - Accessibility
  - Input Monitoring
- Codex mode is intentionally unsandboxed. Do not describe it as a hardened or safe-by-default mode.

## Choose One Install Path

Use the first path that matches the user's request.

### Path A: Install from a Release Asset

Use this when the user wants the quickest install and a release zip exists.

1. Download the latest release asset for macOS.
2. Unzip `MiWhisper.app`.
3. Move it to `/Applications` unless the user wants another location.
4. Launch the app.
5. Ask the user to grant the required macOS permissions when prompted.
6. Verify that `Fn` dictation works.

Suggested shell flow:

```bash
set -euo pipefail

TMP_DIR="$(mktemp -d)"
cd "$TMP_DIR"

gh release download --repo mikecobian09/miwhisper --pattern 'MiWhisper-*-macos-arm64.zip'
unzip -q MiWhisper-*-macos-arm64.zip
rm -rf /Applications/MiWhisper.app
mv MiWhisper.app /Applications/
open /Applications/MiWhisper.app
```

If `gh` is unavailable, use the release URL the user provides.

### Path B: Build from Source

Use this when the user wants the current repo version, local changes, or development setup.

1. Ensure command-line prerequisites are present.
2. Bootstrap `whisper.cpp` and the default model.
3. Build the Xcode project.
4. Launch the built app.
5. Ask the user to grant the required macOS permissions.
6. Verify dictation.

## Preflight Checks

Run these first for a source install:

```bash
set -euo pipefail

uname -s
uname -m
xcodebuild -version
cmake --version
```

Expected:

- `uname -s` should be `Darwin`
- `uname -m` should ideally be `arm64`
- `xcodebuild` should exist
- `cmake` should exist

If `cmake` is missing, install it before continuing.

Homebrew example:

```bash
brew install cmake
```

## Source Install Procedure

From the repository root:

```bash
set -euo pipefail

./scripts/bootstrap-whispercpp.sh

xcodebuild \
  -project MiWhisper.xcodeproj \
  -scheme MiWhisper \
  -configuration Release \
  -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO \
  build

open build/Release/MiWhisper.app
```

Notes:

- `bootstrap-whispercpp.sh` builds the vendored `whisper.cpp` runtime and ensures `models/ggml-small.bin` exists.
- `CODE_SIGNING_ALLOWED=NO` is appropriate for local builds.
- If the repository ships with `vendors/whisper.cpp` already present but not as a Git checkout, the bootstrap script must still treat it as valid source. Do not assume `vendors/whisper.cpp/.git` is required.

## If Apple Silicon Has the Wrong `cmake`

On Apple Silicon, an x86_64-only `cmake` under Rosetta is a bad default.

Preferred retry:

```bash
CMAKE_BIN=/opt/homebrew/bin/cmake ./scripts/bootstrap-whispercpp.sh
```

Only if the user explicitly accepts the trade-off:

```bash
ALLOW_TRANSLATED_CMAKE=1 ./scripts/bootstrap-whispercpp.sh
```

## Optional Codex Setup Check

Only do this if the user wants the Codex bridge to work.

Check whether Codex exists:

```bash
test -x /Applications/Codex.app/Contents/Resources/codex && echo "codex found"
```

If the app is installed elsewhere, the user can set the path later in MiWhisper Settings.

Do not claim Codex mode is configured just because the binary exists. If asked, verify it separately.

## Permissions the User Must Approve

MiWhisper depends on these macOS permissions:

- Microphone
- Accessibility
- Input Monitoring

Tell the user clearly:

1. Launch MiWhisper.
2. Try normal dictation with `Fn`.
3. When macOS asks for permissions, approve them.
4. If `Fn` still does nothing, check whether macOS is using Globe/Fn for emoji or dictation.

## Validation Checklist

After install, verify these in order.

### 1. Local Whisper Runtime

```bash
./scripts/smoke-test-whisper.sh
```

This should produce a transcript from the bundled sample audio.

### 2. App Build Exists

For a source build:

```bash
test -d build/Release/MiWhisper.app && echo "app built"
```

For a release install:

```bash
test -d /Applications/MiWhisper.app && echo "app installed"
```

### 3. Dictation Path

Manual validation:

1. Focus any text field.
2. Hold `Fn`.
3. Speak a short sentence.
4. Release `Fn`.
5. Confirm the transcript is inserted, or at least copied via fallback.

### 4. Codex Path

Manual validation:

1. Hold `Command + Fn`.
2. Speak a short prompt.
3. Release.
4. Confirm a Codex session window opens.

## Troubleshooting

### `Fn` does not trigger recording

- Check Input Monitoring permission.
- Check macOS Globe/Fn shortcut settings.
- Relaunch the app after granting permissions.

### App builds but dictation fails immediately

- Run `./scripts/smoke-test-whisper.sh`
- Confirm `models/ggml-small.bin` exists
- Confirm `vendors/whisper.cpp/build/bin/whisper-cli` exists

### Paste fails

- Check Accessibility permission
- MiWhisper can still fall back to clipboard insertion

### Codex session does not open

- Verify Codex is installed
- Verify the Codex executable path in Settings
- Confirm Codex works outside MiWhisper before blaming the app

## What Not To Do

- Do not promise a sandboxed or hardened Codex mode.
- Do not claim macOS permissions were granted automatically.
- Do not commit machine-local files such as:
  - `AGENTS.md`
  - `.playwright-cli/`
  - `xcuserdata/`
  - `.DS_Store`
  - local model binaries in `models/*.bin`
- Do not describe a failed preflight as success.

## Minimal Agent Response Template

If a user asks an agent to install MiWhisper, a good concise response is:

1. I will verify macOS, Xcode, and `cmake`.
2. I will bootstrap `whisper.cpp`, build MiWhisper, and launch it.
3. You will still need to approve Microphone, Accessibility, and Input Monitoring in macOS.
4. After that I will validate `Fn` dictation and, if you want, `Command + Fn` Codex mode.

