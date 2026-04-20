# Contributing to MiWhisper

MiWhisper is a practical macOS developer tool, not a generic dictation product. The best contributions make the core workflow faster, clearer, or safer without bloating the app.

## Before You Start

- Search existing issues first.
- For large changes, open an issue before implementing.
- Keep the scope narrow. Small, reviewable pull requests move faster.

## Local Setup

If you want an agent to do the installation and validation, point it at [INSTALL_FOR_AGENTS.md](./INSTALL_FOR_AGENTS.md).

Manual setup from the repo root:

```bash
./scripts/bootstrap-whispercpp.sh

xcodebuild \
  -project MiWhisper.xcodeproj \
  -scheme MiWhisper \
  -configuration Debug \
  -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO \
  build
```

## Requirements

- macOS 14 or later
- Apple Silicon strongly preferred
- Xcode 15 or later
- `cmake` in `PATH`

## What Good Contributions Look Like

- Preserve the fast local dictation path.
- Keep the menu bar workflow lightweight.
- Prefer explicit behavior over hidden automation.
- Document security-relevant trade-offs clearly.
- Avoid hardcoding personal paths, machines, users, or private tooling assumptions.

## What To Avoid

- Publishing local artifacts such as `AGENTS.md`, `.playwright-cli/`, `xcuserdata/`, `.DS_Store`, or local model binaries.
- Adding cloud dependencies to the default dictation path.
- Turning Codex mode into something that looks sandboxed when it is not.
- Merging unrelated refactors into a feature PR.

## Testing

Minimum useful validation for most changes:

```bash
./scripts/smoke-test-whisper.sh

xcodebuild \
  -project MiWhisper.xcodeproj \
  -scheme MiWhisper \
  -configuration Release \
  -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Manual checks when relevant:

- `Fn` dictation works in a normal text field
- `Command + Fn` opens a Codex session
- Generated Markdown and HTML render correctly
- Session history is still recoverable

## Pull Request Checklist

- The change is scoped and explained clearly.
- README or docs are updated if behavior changed.
- No personal files or machine-local artifacts are included.
- The project still builds locally.
- Security-sensitive behavior is described honestly.

## Review Expectations

This project values direct technical critique. Expect review comments to focus on:

- regressions;
- hidden complexity;
- privacy and filesystem risk;
- unclear UX trade-offs;
- missing validation.
