# Changelog

All notable public-facing changes to MiWhisper should be recorded here.

## v0.1.0-alpha.14

- Added the native iOS Companion wrapper in `CompanionIOS/`, loading the Mac-hosted Companion PWA inside `WKWebView` with native read-aloud and car-mode command hooks.
- Added `scripts/install-ios-companion.sh` for installing the iOS wrapper on a paired device after selecting an Apple Development team.
- Added an opt-in Companion watchdog that installs a user LaunchAgent to relaunch MiWhisper after crashes while respecting normal user quits.
- Added Companion PWA runtime controls for Plan, Fast mode, reasoning effort, Full Access visibility, and completion notifications.
- Added local follow-up queueing for busy Companion sessions while keeping immediate sends mapped to live Codex steering.
- Hardened Codex app-server JSON-RPC handling so server-originated requests are surfaced instead of being mistaken for responses.
- Added a live Companion session stream and Codex status strip so PWA sessions reflect Mac-side activity, active commands, patches, warnings, and file/tool counts without a manual refresh.
- Expanded Codex app-server notification handling for live plan updates, turn diffs, file-change deltas, token usage, and protocol warnings.
- Added first-pass Companion On-Request plumbing: sessions can be started with workspace-write/on-request access and command/file-change approval requests are rendered as actionable mobile approval cards.
- Restyled the Companion PWA toward Codex's native app feel with a neutral SF-style palette, calmer sidebar, open assistant turns, softer user bubbles, compact runtime controls, quieter activity/tool/approval surfaces, stronger dark mode, and a less branded composer.
- Reduced Companion PWA flicker by making session lists, live status, topbar, and active chat renders signature-based/coalesced instead of replacing DOM on every SSE/polling tick.
- Improved Companion PWA live update reliability by including live status/detail and streamed activity text tails in render signatures, plus a visible PWA version marker and service-worker controller reload for stale installed clients.
- Changed Companion PWA Codex turns to render a chronological timeline, keeping reasoning text, final text, commands, tools, approvals, and file edits interleaved instead of collapsing them into one response plus a final activity bucket.
- Refined Companion PWA mobile chrome with a translucent compact topbar, slimmer runtime controls, a lower-profile composer, shorter input copy, and contextual helper text so responses keep more visual priority.
- Added visible Codex context compaction status entries so Companion shows when Codex is compacting older context and when compaction has completed.
- Fixed Companion PWA prompt sends so existing-session posts apply the returned live session detail immediately and restart the session stream, preventing successful sends from looking like no-ops.
- Raised the Codex app-server WebSocket message limit so long native Codex threads can be resumed from Companion instead of disconnecting with oversized frames.
- Moved Codex session history persistence out of `UserDefaults` and into an Application Support JSON file to avoid macOS preference-size failures that could make the PWA flicker or revert session state.
- Reduced active-chat flicker further by patching stable timeline nodes instead of clearing and rebuilding the full conversation on each live update.
- Made the live status strip update text and metric nodes in place instead of replacing the whole top status surface during active runs.
- Grouped consecutive command/tool/patch activity in Companion turns into a single collapsible execution summary so Codex text and final responses stay visually primary without losing traceability.
- Added clearer Companion run-state indicators with distinct icons/colors for thinking, working, attention, and finished states in the live strip plus working-state chips in the thread list.
- Added first-pass Companion image attachments from camera/library, wiring PWA uploads through local files into Codex app-server `UserInput` instead of smuggling images into text prompts.
- Made Companion continuation sends carry runtime overrides for the next non-busy turn, armed `/subagents` as a one-shot composer mode, and removed the Git commit shortcut from this non-Git parity pass.
- Expanded Companion On-Request handling to surface general Codex permission requests as actionable mobile cards, and made the PWA speed control explicit with Default/Fast/Flex service-tier choices.
- Smoothed Companion live updates by reusing visible assistant/thinking DOM nodes during streaming updates and disabling implicit smooth-scroll during pinned auto-follow.
- Made Companion timeline updates incremental inside assistant turns so streaming text patches individual timeline items instead of rebuilding the whole assistant response block, and fixed final answers with Markdown bullet lists being misclassified as diffs.
- Bumped the Companion PWA service worker cache so installed browser apps refresh the runtime-control UI.

## v0.1.0-alpha.13

- Added `gpt-5.5` to the selectable Codex model presets.
- Rebuilt release dependencies with compiler prefix mapping so public app binaries do not retain local workspace paths.

## v0.1.0-alpha.12

- Improved Companion PWA Markdown rendering for pipe tables, including alignment rows, escaped pipes, and pipes inside inline code.
- Reduced Markdown preview padding and prevented horizontal page scroll by wrapping long table cells, long words, and code/preformatted lines.
- Bumped the Companion PWA service worker cache so installed browser apps refresh the Markdown rendering fixes.

## v0.1.0-alpha.11

- Restored and strengthened the Companion PWA voice transcription progress indicator while audio is prepared, uploaded, and transcribed.
- Bumped the Companion PWA service worker cache so installed browser apps refresh the fixed voice UI.

## v0.1.0-alpha.10

- Fixed Companion PWA voice transcription by accepting 16 kHz mono 16-bit WAV files written with the WAVE_FORMAT_EXTENSIBLE PCM container.

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
