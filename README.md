# MiWhisper

MiWhisper is a macOS menu bar app for fast local dictation with an optional voice-to-Codex bridge.

Hold `Fn` to record, release to transcribe locally with `whisper.cpp`, and paste into the active app. Hold `Command + Fn` to transcribe your speech as a literal prompt and open a live Codex session window you can continue from the keyboard or by voice.

> Status: early alpha, but already useful. The dictation path is local-first. The Codex path is intentionally optimized for a trusted personal development machine, not for a sandboxed multi-user environment.

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

For most users, the easiest install path is to ask their coding agent to do it. Point the agent at [INSTALL_FOR_AGENTS.md](./INSTALL_FOR_AGENTS.md) and let it run the setup and validation flow, then approve the required macOS permissions when prompted.

1. Build the bundled `whisper.cpp` dependencies and download the default model:

```bash
./scripts/bootstrap-whispercpp.sh
```

2. Open [MiWhisper.xcodeproj](./MiWhisper.xcodeproj) in Xcode.

3. Run the `MiWhisper` target.

4. Grant permissions when macOS asks for them.

5. Hold `Fn`, speak, release, and verify that the transcript pastes into the active app.

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

- If the file depends on relative assets, use the in-app reader first. MiWhisper loads HTML files with their parent folder as `baseURL`.

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

- It is currently optimized for the author’s Apple Silicon development setup.
- Some defaults are still more developer-oriented than end-user-oriented.
- Codex mode is intentionally unsandboxed.
- The app is not yet packaged as a polished drag-and-drop release.

That said, the core workflow already works well enough to justify open sourcing it.

## Contributing

Issues and pull requests are welcome, especially for:

- path and onboarding cleanup for non-author machines;
- packaging and release automation;
- better permission diagnostics;
- safer optional Codex modes;
- UI polish around session history, diffs, and activity blocks.

Before making large changes, open an issue so the direction is clear first.

## License

This project is licensed under the MIT License. See [LICENSE](./LICENSE).
