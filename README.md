# MiWhisper

[![Release](https://img.shields.io/github/v/release/mikecobian09/miwhisper?display_name=tag)](https://github.com/mikecobian09/miwhisper/releases)
[![License](https://img.shields.io/github/license/mikecobian09/miwhisper)](./LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-black)](#requirements)

MiWhisper is a macOS menu bar app for local push-to-talk dictation, voice-driven Codex sessions, and a localhost Companion web app you can use from a browser or install as a PWA.

Hold `Fn` to dictate into the focused app. Hold `Command + Fn` to turn your voice into a Codex prompt. Open the Companion at `http://127.0.0.1:6009` to manage Codex threads, continue sessions, preview generated files, and record prompts from a browser.

> Status: early alpha. The dictation path is local-first. The Codex and Companion paths are for trusted developer machines and should be treated as powerful local automation surfaces.

## What You Get

- Native macOS menu bar utility.
- Local transcription with bundled `whisper.cpp`.
- Push-to-talk dictation with `Fn`.
- Voice-to-Codex prompts with `Command + Fn`.
- Persistent Codex sessions with running state, history, stop/focus controls, and thread resume.
- Workspace-aware Codex thread catalog from local Codex state.
- Companion web app served from the Mac on `127.0.0.1:6009`.
- Installable PWA for the Companion UI.
- Companion HTTP API for sessions, voice transcription, file search, raw file reads, and rendered previews.
- Markdown and HTML rendering for Codex responses and generated files.
- Usage stats with daily persisted buckets and saved-time estimates.
- Optional launch-at-login setting.

## Safety Model

MiWhisper is designed to be useful without quietly taking over a machine.

Public release defaults:

- The Companion server starts on loopback only: `127.0.0.1:6009`.
- MiWhisper does not configure Tailscale Serve automatically.
- File preview and raw file APIs are restricted to discovered workspaces plus `~/Downloads/MiWhisper`.
- Dictation audio is transcribed locally with `whisper.cpp`.
- Browser-uploaded Companion audio is normalized locally and then transcribed locally.

Important limits:

- Codex mode is not a sandbox. It can run whatever your local Codex installation is allowed to run.
- Companion has no login screen. Treat it as local-only unless you deliberately expose it through a trusted private network.
- If you expose Companion with Tailscale Serve, anyone with access to that tailnet endpoint may be able to control MiWhisper's Companion API.
- Release builds are currently unsigned and not notarized.

This is not a multi-user server, a hardened remote admin panel, or a consumer-grade signed app yet.

## Requirements

- macOS 14 or later.
- Apple Silicon strongly recommended.
- Xcode 15 or later if building from source.
- `cmake` available in `PATH` if building bundled `whisper.cpp`.
- Microphone permission.
- Accessibility permission for inserting text into the focused app.
- Input Monitoring permission for reliable `Fn` capture.

Optional:

- Codex installed locally for voice-to-Codex and Companion session workflows.
- Tailscale if you intentionally want to expose the Companion PWA to your own tailnet.

## Install From a Release

1. Download the latest macOS arm64 zip from [Releases](https://github.com/mikecobian09/miwhisper/releases).
2. Unzip `MiWhisper.app`.
3. Move it to `/Applications`.
4. Launch it.
5. Approve Microphone, Accessibility, and Input Monitoring when macOS asks.

Because current releases are unsigned and not notarized, macOS Gatekeeper may require an additional confirmation before the first launch.

## Build From Source

The source install path is still developer-oriented. If you are using a coding agent, point it at [INSTALL_FOR_AGENTS.md](./INSTALL_FOR_AGENTS.md).

1. Bootstrap `whisper.cpp` and the default model:

```bash
./scripts/bootstrap-whispercpp.sh
```

2. Open [MiWhisper.xcodeproj](./MiWhisper.xcodeproj) in Xcode.

3. Run the `MiWhisper` target.

4. Grant the required macOS permissions.

5. Hold `Fn`, speak, release, and verify that the transcript appears in the active app.

If your ARM Homebrew `cmake` is not first in `PATH`, run:

```bash
CMAKE_BIN=/opt/homebrew/bin/cmake ./scripts/bootstrap-whispercpp.sh
```

The bootstrap script intentionally refuses x86_64-only `cmake` on Apple Silicon unless you opt in:

```bash
ALLOW_TRANSLATED_CMAKE=1 ./scripts/bootstrap-whispercpp.sh
```

## Core Workflow

### Dictation

1. Hold `Fn`.
2. Speak.
3. Release `Fn`.
4. MiWhisper transcribes locally.
5. The transcript is inserted into the focused app, with clipboard fallback if direct insertion fails.

### Codex

1. Hold `Command + Fn`.
2. Speak the prompt exactly as you want Codex to receive it.
3. Release the keys.
4. MiWhisper transcribes locally.
5. A Codex session opens with the prompt.
6. Continue, stop, focus, or reopen the session from MiWhisper.

Codex sessions are persisted locally. MiWhisper can also hydrate native Codex thread history so old threads show useful context instead of empty records.

## Companion

Companion is the built-in browser UI served by MiWhisper.

Open:

```text
http://127.0.0.1:6009
```

Use it to:

- browse detected Codex workspaces;
- see native and MiWhisper-imported Codex threads in one catalog;
- open native Codex threads on demand;
- continue a session from the browser;
- stop or focus a running session;
- record voice prompts from the browser;
- search workspace files;
- preview generated HTML, Markdown, images, PDFs, text, logs, diffs, and patches.

The PWA can be installed from the browser's install/share menu. On iPhone or iPad, microphone capture requires a secure context, so plain `http://127.0.0.1` is only useful on the Mac itself. For an iPhone or iPad, assume you need the Tailscale Serve step below.

## Remote PWA With Tailscale

MiWhisper does not configure Tailscale Serve automatically in public builds. That is deliberate: `tailscale serve --bg --yes 6009` can overwrite an existing Serve configuration. But for iPhone/iPad microphone capture and for the native iOS wrapper, the HTTPS tailnet URL is the expected setup.

Run this on the Mac after MiWhisper is open:

```bash
tailscale serve --bg --yes 6009
```

Then open the HTTPS tailnet URL that Tailscale prints, for example `https://your-mac.your-tailnet.ts.net`. Keep in mind that the Companion API can continue Codex sessions and read allowed workspace files, so only expose it on a network you trust.

To inspect or remove your Tailscale Serve configuration:

```bash
tailscale serve status
tailscale serve reset
```

## iOS Companion Wrapper

The optional iOS app in [CompanionIOS](./CompanionIOS) is a thin native wrapper around the same Companion PWA served by the Mac. It does not contain a separate chat client. Its job is to load the HTTPS Tailnet URL in `WKWebView` and provide native iOS speech for read-aloud and car-mode voice commands.

Before using the iOS wrapper:

1. Launch MiWhisper on the Mac.
2. Run `tailscale serve --bg --yes 6009` on the Mac.
3. Open `tailscale serve status` and copy the HTTPS URL.
4. Build/install the iOS wrapper.
5. In the iOS wrapper, set the Companion URL to that HTTPS Tailnet URL.

Build for the simulator:

```bash
xcodebuild -project CompanionIOS/MiWhisperCompanion.xcodeproj \
  -scheme MiWhisperCompanion \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -derivedDataPath build/CompanionIOS \
  build
```

Install on a paired iPhone:

```bash
MIWHISPER_IOS_DEVICE_ID=<device-id> \
MIWHISPER_IOS_TEAM_ID=<team-id> \
./scripts/install-ios-companion.sh
```

Find the device id with `xcrun xctrace list devices` or `xcrun devicectl list devices`. If iOS blocks the first launch, trust the Apple Development profile in Settings > General > VPN & Device Management, then open MiWhisper Companion manually.

## Companion API

The API is local and intentionally small. Responses are JSON unless noted.

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | `/api/health` | Basic health check |
| `GET` | `/api/bootstrap` | App name, local URL, workspaces, and session summaries |
| `GET` | `/api/workspaces` | Detected workspaces |
| `GET` | `/api/sessions` | Unified Codex thread/session list |
| `POST` | `/api/sessions` | Create a new Codex session from a prompt |
| `POST` | `/api/sessions/open-thread` | Import/open a native Codex thread |
| `GET` | `/api/sessions/{id}` | Session detail and activity |
| `POST` | `/api/sessions/{id}/messages` | Continue a session |
| `POST` | `/api/sessions/{id}/stop` | Stop a running session |
| `POST` | `/api/sessions/{id}/focus` | Focus the native session window |
| `GET` | `/api/sessions/{id}/stream` | Server-sent session updates |
| `PATCH` | `/api/sessions/{id}` | Rename a local session |
| `DELETE` | `/api/sessions/{id}` | Delete a non-running local session |
| `POST` | `/api/voice/transcribe` | Upload browser audio for local transcription |
| `GET` | `/api/workspaces/{id}/files?q=...` | Search allowed workspace files |
| `GET` | `/api/files/raw?path=...` | Read an allowed file |
| `GET` | `/preview?path=...` | Render or redirect an allowed preview |

Example:

```bash
curl http://127.0.0.1:6009/api/health
```

Create a session:

```bash
curl -X POST http://127.0.0.1:6009/api/sessions \
  -H 'Content-Type: application/json' \
  -d '{"prompt":"Summarize the current repository structure."}'
```

## Settings

Current settings include:

- Launch at login.
- Whisper model selection.
- Model downloads for bundled presets.
- Transcription language.
- Literal transcription or translation to English.
- Codex executable path.
- Default Codex model.
- Default Codex reasoning effort.
- Default Codex service tier.

The default Codex executable path is:

```text
/Applications/Codex.app/Contents/Resources/codex
```

## Permissions

| Permission | Why MiWhisper Needs It |
| --- | --- |
| Microphone | Record dictation and Companion voice prompts |
| Accessibility | Insert text into the focused app |
| Input Monitoring | Detect the `Fn` hotkey reliably |

If `Fn` does nothing, check Input Monitoring and macOS Globe/Fn keyboard settings first.

## Models

The app includes practical model presets rather than treating every Whisper model as equally useful for live dictation.

Good starting points:

- `small`: fastest reasonable default.
- `medium`: useful quality comparison point.
- `large-v3-turbo-q5_0`: stronger quality candidate with a larger footprint.

Helpful scripts:

```bash
./scripts/smoke-test-whisper.sh
./scripts/download-model.sh medium
./scripts/download-model.sh large-v3-turbo-q5_0
./scripts/benchmark-model.sh /path/to/test.wav small medium large-v3-turbo-q5_0
```

## Troubleshooting

### `Fn` Does Nothing

- Confirm Input Monitoring permission.
- Check whether macOS is using Globe/Fn for emoji, dictation, or another system action.
- Quit and reopen MiWhisper after changing permissions.

### Paste Fails

- Confirm Accessibility permission.
- MiWhisper should still copy the transcript to the clipboard as fallback.

### Codex Does Not Launch

- Verify the Codex executable path in Settings.
- Confirm Codex works in Terminal first.
- Check that the target workspace exists and is readable.

### Companion Does Not Open

- Confirm MiWhisper is running.
- Open `http://127.0.0.1:6009/api/health`.
- If another app uses port `6009`, quit that app or restart MiWhisper after freeing the port.

### Mobile Microphone Does Not Work

- iOS and iPadOS require HTTPS for browser microphone capture outside localhost.
- Use a trusted HTTPS path such as Tailscale Serve if you intentionally expose Companion.
- Reload the PWA after changing the Serve setup.

### Generated HTML Opens Blank

- Open the actual generated file from the session file actions.
- Very heavy or browser-specific pages may still work better in Safari or Chrome than in the embedded reader.

## Architecture

High-level pieces:

- `AudioRecorder` records mono PCM audio.
- `WhisperTranscriber` runs local transcription through the embedded `whisper.cpp` bridge.
- `AccessibilityTextInsertion` handles focused-app insertion and clipboard fallback.
- `HotkeyMonitor` captures `Fn` and `Command + Fn`.
- `CodexRunner` launches and streams Codex sessions.
- `CodexPanelController` renders native Codex session windows and generated outputs.
- `CodexThreadCatalog` merges native Codex state with MiWhisper's local session records.
- `CompanionBridge` serves the localhost API, PWA, file previews, and browser voice upload flow.

## Project Docs

- [INSTALL_FOR_AGENTS.md](./INSTALL_FOR_AGENTS.md) for agent-assisted installation and validation.
- [Docs/COMPANION_CODEX_PARITY_PLAN.md](./Docs/COMPANION_CODEX_PARITY_PLAN.md) for the Companion roadmap and current native/PWA split.
- [CONTRIBUTING.md](./CONTRIBUTING.md) for local setup, testing, and pull request expectations.
- [SECURITY.md](./SECURITY.md) for responsible reporting guidance.
- [CHANGELOG.md](./CHANGELOG.md) for release history.
- [CODE_OF_CONDUCT.md](./CODE_OF_CONDUCT.md) for community expectations.

## Contributing

Issues and pull requests are welcome.

High-value areas:

- signing and notarization;
- safer optional Codex execution modes;
- stronger Companion authentication for remote use;
- clearer first-run onboarding;
- permission diagnostics and recovery;
- UI polish for session history, diffs, previews, and activity blocks.

## License

MiWhisper is released under the MIT License. See [LICENSE](./LICENSE).
