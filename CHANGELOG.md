# Changelog

All notable public-facing changes to MiWhisper should be recorded here.

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
