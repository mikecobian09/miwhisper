# Changelog

All notable public-facing changes to MiWhisper should be recorded here.

## v0.1.0-alpha.9

- Fixed the Companion PWA local bridge startup on macOS by binding the loopback endpoint without passing the same port twice to Network.framework.

## v0.1.0-alpha.8

- Fixed installed-app workspace discovery so Codex threads are grouped by their real workspaces instead of collapsing all home-directory threads into one workspace.

## v0.1.0-alpha.7

- Fixed new desktop Codex voice sessions so they start in the currently selected workspace instead of always using MiWhisper's default workspace.

## v0.1.0-alpha.6

- Added the Companion browser app served from the local MiWhisper bridge.
- Added an installable Companion PWA with workspace-aware Codex thread browsing, session continuation, stop/focus controls, and browser voice prompts.
- Added a local Companion HTTP API for health, bootstrap, workspaces, sessions, voice transcription, file search, raw file reads, and rendered previews.
- Added native Codex thread catalog hydration so existing Codex threads can appear alongside MiWhisper-managed sessions.
- Improved Codex activity rendering with clearer final answers, collapsible reasoning/tool output, Markdown body rendering, and local file preview links.
- Tightened public safety defaults: Companion is loopback-only, public builds do not auto-configure Tailscale Serve, and a local workspace path heuristic was removed.
- Rewrote the README around public installation, Companion, the API, PWA setup, privacy limits, and remote-access guidance.

## v0.1.0-alpha.5

- Added a new `Stats` section to the menu bar contextual panel.
- Added daily persisted usage buckets so analytics do not depend on keeping a long transcript history.
- Added period-based usage summaries for day, week, month, year, and all time.
- Added a compact 14-day chart for estimated saved minutes plus usage, word, and audio-time metrics.
- Added a heuristic typing-time-saved estimate based on transcript word counts versus recorded audio time.

## v0.1.0-alpha.4

- Added an opt-in `Launch at login` setting for the menu bar app workflow.
- Added Login Items approval guidance directly in Settings for macOS setups that require manual approval.
- Added a shortcut button to open the macOS Login Items settings screen when approval is needed.
- Included the latest Codex bridge and menu bar fixes in a fresh public release build.

## v0.1.0-alpha.3

- Made the menu bar contextual window much taller and wider so transcript and Codex history fit without feeling cramped.
- Fixed Codex session running indicators so active sessions reliably show as running in the menu bar history.
- Improved Codex session windows with a more reliable live composer, better `Latest Response` backfill, and stronger session-state persistence.
- Improved generated file handling so Codex responses expose direct actions for rendered open, raw open, Finder reveal, and path copy.
- Improved in-app document rendering for generated `.html`, `.htm`, `.md`, and `.markdown` files, especially for file-backed interactive HTML.
- Updated public docs to reflect release installs, current reader behavior, and the unsigned/not-notarized release state.

## v0.1.0-alpha.2

- Added `INSTALL_FOR_AGENTS.md` so coding agents can install and validate MiWhisper end-to-end.
- Added community and maintenance docs: `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`, and `SECURITY.md`.
- Improved the README with public repo links, badges, and clearer installation guidance.
- Clarified current guidance around English translation mode and model choice.
- Fixed the public bootstrap flow so a vendored `whisper.cpp` tree does not require a nested `.git` checkout.

## v0.1.0-alpha.1

- First public prerelease of MiWhisper.
- Local push-to-talk dictation with embedded `whisper.cpp`.
- `Command + Fn` Codex bridge with resumable sessions.
- Rendered Markdown and HTML readers for Codex output and generated files.
