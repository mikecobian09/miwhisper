# Changelog

All notable public-facing changes to MiWhisper should be recorded here.

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
