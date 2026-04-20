# MiWhisper

[![Release](https://img.shields.io/github/v/release/mikecobian09/miwhisper?display_name=tag)](https://github.com/mikecobian09/miwhisper/releases)
[![License](https://img.shields.io/github/license/mikecobian09/miwhisper)](./LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-black)](#requirements)

MiWhisper is a macOS menu bar app for fast local dictation with an optional voice-to-Codex bridge.

Hold `Fn` to record, release to transcribe locally with `whisper.cpp`, and paste into the active app. Hold `Command + Fn` to transcribe your speech as a literal prompt and open a live Codex session window you can continue from the keyboard or by voice.

> Status: early alpha, but already useful. The dictation path is local-first. The Codex path is intentionally optimized for a trusted development machine, not for a sandboxed multi-user environment.

## Why this exists

MiWhisper is built around a narrow goal: make voice useful during real development work without forcing everything through a cloud dictation product.

The core design choices are:

- Native macOS app, menu bar first.
- Local transcription with embedded `whisper.cpp`.
- Push-to-talk instead of always-on listening.
- Low-friction paste into the current app.
- Optional Codex bridge for developer workflows.

## What It Does

- Local push-to-talk dictation with `Fn`.
- Optional `Command + Fn` bridge to Codex.
- Embedded `whisper.cpp` runtime with Metal acceleration on Apple Silicon.
- Per-model presets and download helpers.
- Clipboard-safe paste fallback when direct insertion fails.
- Persistent Codex session windows with history and resume support.
- Rendered HTML and Markdown outputs for Codex responses and generated files.
- Reader windows for generated `.html`, `.htm`, `.md`, and `.markdown` files.

## What It Does Not Try To Be

- A packaged consumer app with polished onboarding.
- A sandboxed Codex client.
- A streaming partial-transcription product.
- A secure multi-tenant assistant.

If you want a hardened product, this repo is not there yet. If you want a transparent developer tool you can inspect and change, it is.

## Requirements

- macOS 14 or later.
- Apple Silicon strongly recommended.
- Xcode 15 or later.
- `cmake` available in `PATH`.
- Microphone permission.
- Accessibility permission for paste-at-cursor.
- Input Monitoring permission for reliable `Fn` capture.

Optional for Codex mode:

- Codex installed locally. The current default path is `/Applications/Codex.app/Contents/Resources/codex`.

## Quick Start

If you just want to try MiWhisper, install the latest release zip.

If you want the smoothest setup, ask your coding agent to do it and point it at [INSTALL_FOR_AGENTS.md](./INSTALL_FOR_AGENTS.md).

### Install From a Release

1. Download the latest macOS arm64 zip from [Releases](https://github.com/mikecobian09/miwhisper/releases).
2. Unzip `MiWhisper.app`.
3. Move it to `/Applications`.
4. Launch it and approve the required macOS permissions.

Current releases are unsigned and not notarized yet, so macOS Gatekeeper may require an extra confirmation step.

### Build From Source

For most users, the easiest source install path is still to ask their coding agent to do it. Point the agent at [INSTALL_FOR_AGENTS.md](./INSTALL_FOR_AGENTS.md) and let it run the setup and validation flow, then approve the required macOS permissions when prompted.

1. Build the bundled `whisper.cpp` dependencies and download the default model:

```bash
./scripts/bootstrap-whispercpp.sh
```

2. Open [MiWhisper.xcodeproj](./MiWhisper.xcodeproj) in Xcode.

3. Run the `MiWhisper` target.

4. Grant permissions when macOS asks for them.

5. Hold `Fn`, speak, release, and verify that the transcript pastes into the active app.

## Project Docs

- [INSTALL_FOR_AGENTS.md](./INSTALL_FOR_AGENTS.md) for Codex, ChatGPT, Claude, or other agents installing the app.
- [CONTRIBUTING.md](./CONTRIBUTING.md) for local setup, testing, and pull request expectations.
- [SECURITY.md](./SECURITY.md) for responsible reporting guidance.
- [CODE_OF_CONDUCT.md](./CODE_OF_CONDUCT.md) for community expectations.
- [CHANGELOG.md](./CHANGELOG.md) for public release history.

## Installation Notes

`bootstrap-whispercpp.sh` will:

- clone `whisper.cpp` into `vendors/whisper.cpp` if needed;
- build static libraries with Metal enabled;
- download the default `small` model into `models/ggml-small.bin`.

On Apple Silicon, the bootstrap script refuses to continue with an x86_64-only `cmake` unless you explicitly override it. That is deliberate. A translated toolchain gives misleading latency numbers.

If you need to force a translated build anyway:

```bash
ALLOW_TRANSLATED_CMAKE=1 ./scripts/bootstrap-whispercpp.sh
```

If your ARM `cmake` is installed in Homebrew’s default location:

```bash
CMAKE_BIN=/opt/homebrew/bin/cmake ./scripts/bootstrap-whispercpp.sh
```

## Usage

### Shortcuts

| Shortcut | Action |
| --- | --- |
| `Fn` | Record dictation and paste the transcript on release |
| `Command + Fn` | Record a literal prompt and open a Codex session on release |

### Dictation Flow

1. Hold `Fn`.
2. Speak.
3. Release `Fn`.
4. MiWhisper transcribes locally.
5. The result is inserted into the current target, or copied to the clipboard if direct insertion fails.

### Codex Flow

1. Hold `Command + Fn`.
2. Speak your prompt.
3. Release the keys.
4. MiWhisper transcribes locally.
5. A new Codex window opens for that prompt.
6. Continue the same session from the composer at the bottom of the window.

Each Codex request opens its own session window. Closing the window does not kill the session while MiWhisper remains open; you can reopen it from the menu bar history.

## Settings

Current settings include:

- Whisper model selection.
- Model downloads for bundled presets.
- Transcription language.
- Literal transcription vs. translation to English.
- Codex executable path.
- Default Codex model.
- Default Codex reasoning effort.
- Default Codex service tier / speed.

If you clone the repo into a different location, review the default paths in Settings on first run. The current codebase still carries developer-oriented defaults.

## Permissions

MiWhisper depends on normal macOS privacy controls:

| Permission | Why it is needed |
| --- | --- |
| Microphone | Record audio for dictation |
| Accessibility | Insert text into the focused app |
| Input Monitoring | Detect the `Fn` hotkey reliably |

If `Fn` does not work but the app is otherwise healthy, the usual cause is macOS intercepting the Globe/Fn key for emoji, dictation, or another system action.

## Privacy and Safety

The privacy model is split:

- Dictation mode is local-first. Audio is recorded locally and transcribed locally with `whisper.cpp`.
- Codex mode is not local-only. Audio is still transcribed locally, but the resulting prompt is sent to your local Codex setup.

Important:

- Codex sessions in this project are intentionally launched with dangerous full-access mode enabled.
- That is acceptable for the author’s trusted personal workflow, but it is not a safe default for an untrusted environment.
- If you publish or share this tool widely, users should understand that Codex mode can inspect local workspaces and act with broad filesystem access.

## Codex Session UX

The Codex bridge is more than “paste a prompt into a CLI.”

Current behavior includes:

- One window per request.
- Resume-able session history.
- Live activity stream grouped into typed blocks such as reasoning, command, tool, patch, and final response.
- Stop and steer controls during active work.
- Rendered Markdown and HTML responses.
- Rendered opening of generated `.html` and `.md` files.
- Context menus for files with open, reveal in Finder, and copy-path actions.

External artifacts generated by Codex sessions are intended to live in `~/Downloads/MiWhisper/` unless they are actual project files that belong in the repo being edited.

## Models

The app currently ships with a few practical presets rather than pretending every Whisper model is equally usable for live dictation.

Useful starting points:

- `small`: fastest reasonable default.
- `large-v3-turbo-q5_0`: stronger quality candidate without the worst memory cost.
- `medium`: available when you want to compare quality trade-offs.
- `Translate to English` is supported, but in practice `small` and `medium` are the safest presets for that mode today. Treat `large-v3-turbo-q5_0` as best-effort until this app has more validation across machines.

Helpful scripts:

```bash
./scripts/smoke-test-whisper.sh
./scripts/download-model.sh medium
./scripts/download-model.sh large-v3-turbo-q5_0
./scripts/benchmark-model.sh /path/to/test.wav small medium large-v3-turbo-q5_0
```

## Troubleshooting

### `Fn` does nothing

- Check Input Monitoring permission.
- Check whether macOS is using Globe/Fn for emoji or another system shortcut.
- Reopen the app after granting permissions.

### Paste fails

- Check Accessibility permission.
- MiWhisper will still copy the transcript to the clipboard as fallback.

### Codex does not launch

- Verify the Codex executable path in Settings.
- Confirm Codex works outside the app first.

### Generated HTML opens blank

- Open the actual generated file from the session file actions instead of pasting raw HTML into the reader.
- File-backed HTML now loads with local read access and JavaScript enabled in the in-app reader.
- Very heavy or browser-specific pages may still look better in Safari or Chrome than in the embedded reader.

### Rendered Markdown looks wrong

- Open the generated `.md` file directly from the session file actions.
- If the content is very HTML-heavy, MiWhisper may render it better as HTML than as Markdown.

## Architecture

At a high level:

- `AudioRecorder` records mono PCM audio.
- `WhisperTranscriber` runs local transcription through the embedded `whisper.cpp` bridge.
- `AccessibilityTextInsertion` and in-app text insertion handle paste targets.
- `HotkeyMonitor` captures `Fn` and `Command + Fn`.
- `CodexRunner` and `CodexPanelController` drive the Codex bridge, session history, activity timeline, and readers.

## Project Status

MiWhisper is useful, but still opinionated and rough in places.

Known realities:

- It is currently optimized for Apple Silicon development setups.
- Some defaults are still more developer-oriented than end-user-oriented.
- Codex mode is intentionally unsandboxed.
- Downloadable release zips exist, but they are not yet signed or notarized.

That said, the core workflow already works well enough to justify open sourcing it.

## Contributing

Issues and pull requests are welcome.

High-value contribution areas right now:

- onboarding cleanup for non-author machines;
- packaging, signing, and notarization;
- better permission diagnostics and recovery paths;
- safer optional Codex modes;
- UI polish around session history, diffs, and activity blocks.

See [CONTRIBUTING.md](./CONTRIBUTING.md) before opening a pull request.

## License

This project is licensed under the MIT License. See [LICENSE](./LICENSE).
