# Companion Codex Parity Plan

This document tracks the path for making MiWhisper Companion feel like the Codex app on iPhone while keeping MiWhisper's own advantages: local dictation, local transcription, Mac menu-bar lifecycle, and shared Codex thread history.

The target is not to clone Remodex wholesale. The target is a Codex-native mobile surface backed by MiWhisper's local bridge.

## Product Bar

Companion should feel like a real mobile Codex client:

- the composer exposes the same runtime choices users expect before a turn starts;
- a running turn can be steered without losing context;
- follow-up prompts can be queued when the user does not want to interrupt the current turn;
- the timeline shows live thinking, plans, commands, diffs, file changes, and final answers with Codex-like density;
- the bridge makes it obvious when it is connected, degraded, waiting for input, or blocked on approval;
- advanced actions such as git push are never hidden behind casual UI affordances.

## Current Foundation

MiWhisper already uses the Codex app-server for the core session lifecycle:

- `thread/start`
- `thread/resume`
- `turn/start`
- `turn/steer`
- `turn/interrupt`

The current bridge also persists MiWhisper session records that map back to real Codex thread ids, so Companion sessions continue to appear in the shared Codex session history.

The current app-server integration is correct for turn execution, but it is intentionally narrow. A Codex-like Companion needs to consume more of the protocol and handle server-originated requests, not only notifications.

## App-Server Gaps To Close

Before adding high-risk UI actions, the runner should distinguish JSON-RPC responses from server requests. Server requests include approval prompts, user input requests, and MCP/tool callbacks. Today full access hides most of those cases, but On-Request mode depends on them.

Required protocol work:

- handle JSON-RPC messages with both `id` and `method` as server requests, not responses;
- support or explicitly reject approval requests with a visible timeline item;
- handle `item/tool/requestUserInput` and related structured user input requests;
- consume `thread/tokenUsage/updated` for context indicators;
- consume `turn/diff/updated`, `turn/plan/updated`, `item/fileChange/outputDelta`, and `item/fileChange/patchUpdated` for richer timeline and file-change summaries;
- expose `model/list` and `account/rateLimits/read` through a small bridge runtime endpoint.

## Feature Plan

### 1. Fast Mode

Status: backend supported, PWA UI incomplete.

MiWhisper already stores `CodexServiceTier` and forwards `serviceTier` to the app-server. Companion should expose a compact runtime control in the composer:

- Default
- Fast
- Flex

Fast should be visible in the composer state before sending a new turn. It should persist per browser install using local storage, with global defaults coming from the Mac app.

### 2. Plan Mode

Status: can ship first as a prompt-level mode; later can integrate app-server plan notifications more deeply.

Companion should provide a Plan toggle beside runtime controls. When active, the outgoing prompt should be wrapped with an explicit planning instruction that asks Codex to present a concise implementation plan before file edits. The timeline should render plan deltas and plan summaries as first-class collapsible plan blocks.

### 3. Subagents

Status: prompt command first; native app-server orchestration later.

The `/subagents` command should arm a composer mode instead of dumping raw slash text into the prompt. First implementation can send a structured prompt asking Codex to split work into bounded parallel tasks and use available sub-agent tooling when present. Native support should come after MiWhisper can represent spawned agent threads and open them from the mobile timeline.

### 4. Steer Active Runs

Status: backend supported; PWA semantics should be clearer.

When `session.isBusy` is true, sending immediately should be labeled as `Steer`, because `CodexRunner` forwards to `turn/steer`. The user should see that this changes the active turn rather than starting a new turn.

### 5. Queue Follow-Up Prompts

Status: missing.

Companion should let users choose between:

- `Steer now`
- `Queue after current turn`

Queued drafts should survive reloads in local storage and drain after a session transitions from busy to idle. The queue must be visible above the composer with restore, remove, and send-now actions.

### 6. In-App Notifications

Status: partial browser title updates; Notification API should be added.

The PWA should request notification permission only after a user gesture. It should notify when:

- a running turn completes while the PWA is backgrounded;
- a turn fails;
- Codex needs attention, approval, or structured user input.

Notifications must not include long prompts, secrets, or file contents.

### 7. Git Actions

Status: not safe to expose as push/commit controls yet.

The first bridge milestone should be read-only:

- branch;
- dirty state;
- changed files;
- diff totals;
- recent commits.

Write actions come after access mode and confirmation UI exist:

- pull;
- branch switch;
- create branch;
- commit with generated draft message;
- push.

Hard reset and destructive operations should require explicit confirmation and should not be part of the first parity pass.

### 8. Reasoning Controls

Status: backend supported, PWA UI incomplete.

Companion should expose:

- Default
- Low
- Medium
- High
- Extreme

The selected value should be included in new session creation and open-thread import when relevant. Resumed local sessions should continue using their stored session settings unless the user changes them deliberately.

### 9. Access Controls

Status: currently hardwired to full access.

Full Access is the current behavior: `approvalPolicy: never` plus danger-full-access sandbox settings. On-Request cannot be honest until server requests are handled. The UI can show current access as Full Access, but should not offer On-Request as an actionable mode until approvals are wired.

### 10. Photo Attachments

Status: missing.

The UI can add camera/library intake first, but sending images requires `CodexRunner` to build app-server `UserInput` arrays with non-text content. This should be implemented at the runner layer rather than smuggling base64 into text prompts.

### 11. Background Bridge Service

Status: bridge watchdog implemented; external relaunch helper is opt-in.

MiWhisper still hosts the Companion bridge inside the main app. That is deliberate: it keeps local transcription, Codex session state, and mobile control in one process instead of splitting Companion into a second Codex client.

The bridge now has an internal watchdog. If the HTTP listener fails or disappears unexpectedly, MiWhisper records the failure, restarts the listener, and asks Tailscale Serve to re-assert the Companion route. `/api/health` exposes `restartCount` and `lastBridgeError` so the PWA or diagnostics can distinguish a healthy bridge from one that has recently recovered.

For full app crashes, Settings includes an opt-in `Keep Companion alive after crashes` toggle. It installs a user LaunchAgent (`com.miwhisper.companion-watchdog`) that checks whether MiWhisper is running and reopens it if it crashed. A normal app Quit writes an intentional-quit marker, so the LaunchAgent does not reopen MiWhisper against the user's intent.

### 11.1 Local Read-Aloud Voice

Status: browser speech is the web fallback; native iOS speech is available in the thin iOS wrapper.

Double-clicking, long-pressing, or using the speaker action on a final assistant text block reads only the final text aloud, not tool output or diffs. In Safari/PWA mode this uses `speechSynthesis`. In `CompanionIOS/`, the same PWA runs inside `WKWebView`; the PWA detects `window.miwhisperNativeSpeech` and delegates read-aloud to iOS `AVSpeechSynthesizer`.

The old server-side TTS experiment has been removed from the bridge. The current trade-off is deliberate: no Mac-side neural runtime stays warm, and native speech can be tested on iPhone without duplicating the PWA UI or Codex logic.

### 11.2 Car Mode

Status: first PWA pass implemented.

Car Mode is deliberately not a full Codex UI for driving. When active, Companion hides the dense chat timeline and composer controls, keeps a large status panel, and exposes only the controls that make sense in a low-attention context:

- `Hablar`, which records through the existing local voice transcription path and auto-sends the transcript as a prompt;
- `Repetir`, which reads the latest car-safe summary;
- `Parar`, which cancels recording, stops speech, or stops the active turn depending on what is running;
- summary detail modes: brief, normal, and detail.

The PWA currently generates the car-safe spoken summary locally from the final assistant text. It deliberately does not prepend a visible "car mode" instruction to user prompts, because that pollutes normal thread history when the user leaves Car Mode. A later implementation can add a hidden/session-level instruction if the bridge supports it cleanly.

The safety boundary is intentional: Car Mode should summarize, queue, and dictate. It should not encourage reviewing long diffs, approving destructive actions, or making complex development decisions while driving.

### 12. Live Streaming

Status: supported through SSE + polling fallback.

Improve fidelity by streaming additional app-server notifications and grouping tool bursts. Keep the current SSE/polling fallback because mobile browsers can suspend background connections.

### 13. Shared Codex Thread History

Status: supported.

Keep real Codex thread ids as canonical continuity. Do not fork Companion into a separate chat store. Any mobile-created or imported session should remain mapped to a Codex thread visible from the desktop Codex app.

## Implementation Phases

### Phase 1: Codex-Like Composer And Runtime Controls

- Add compact runtime bar: model, reasoning, speed, plan, access.
- Persist Companion runtime preferences in local storage.
- Send `reasoningEffort` and `serviceTier` from the PWA when creating sessions or opening native threads.
- Change busy-send affordance to `Steer`.
- Add visible queued-draft panel and local draining.
- Add Notification API permission and completion notifications.

Initial implementation status:

- Plan, Fast, reasoning, Full Access visibility, notification toggle, and busy Steer/Queue controls are present in the Companion composer.
- `serviceTier` and `reasoningEffort` are applied to new sessions, because existing `/messages` continuation currently accepts only a prompt.
- Busy-session queueing is local to the PWA and drains after the active turn becomes idle.
- The PWA now has a live Codex status strip fed by bridge session detail: it surfaces active run state, thread id, command/tool/patch/file counts, warnings, errors, and Mac focus/stop actions.
- The session list now has an SSE catalog stream, so Mac-side MiWhisper/Codex activity appears in the Companion sidebar without requiring manual refresh.
- On-Request can now be selected for new Companion sessions. It starts app-server turns with `approvalPolicy: on-request` and `workspace-write` sandbox settings.
- Car Mode is available from the top bar. It persists locally, collapses the PWA into a large status panel, auto-sends dictated prompts, and reads brief/normal/detail summaries instead of the full timeline.

### Phase 2: Protocol Completeness

- Split JSON-RPC server requests from responses.
- Add explicit unsupported handling for approval and structured input requests.
- Add token usage, plan update, diff update, and file-change streaming.
- Add bridge runtime endpoint for model/rate-limit metadata.

Initial implementation status:

- JSON-RPC server requests are separated from responses and surfaced as visible attention items.
- The runner now consumes `thread/tokenUsage/updated`, `turn/diff/updated`, `turn/plan/updated`, `item/fileChange/outputDelta`, `item/fileChange/patchUpdated`, `command/exec/outputDelta`, and warning-style notifications.
- Command and file-change approval requests are held open, rendered in the Companion timeline, and can be approved once, approved for the session, declined, or cancelled from the PWA.
- Permissions, MCP elicitations, dynamic tool calls, and structured user-input requests are still surfaced as unsupported attention items rather than silently accepted.

### Phase 3: Attachments And Subagents

- Add image attachment intake in the PWA.
- Extend session send payloads to carry typed input items.
- Extend `CodexRunner` to send app-server `UserInput` arrays.
- Convert `/subagents` from prompt macro to native thread/subagent representation when app-server support is available.

### Phase 4: Git Workflows

- Add read-only git status endpoint and UI.
- Add branch switching with confirmation.
- Add generated commit message preview.
- Add commit/pull/push only after access mode and approval handling are in place.

### Phase 5: Visual Parity Pass

- Reduce blue-heavy surfaces and use Codex-like neutral tokens.
- Flatten assistant blocks.
- Make tool calls, plans, diffs, and file summaries dense and scan-friendly.
- Add a compact run summary pane for active sessions on larger screens.

## Non-Goals For The First Pass

- public relay;
- replacing MiWhisper with a separate iOS app;
- push notifications through APNS;
- destructive git reset from mobile;
- claims that On-Request mode works before approval server requests are implemented.
