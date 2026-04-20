# Security Policy

MiWhisper is an early alpha developer tool. The dictation path is local-first, but Codex mode is intentionally unsandboxed and designed for trusted local machines.

That means security reports are useful and expected, especially around:

- filesystem access;
- prompt injection through generated content;
- arbitrary command execution surfaces;
- privacy leaks in logs, history, or rendered files;
- unsafe defaults that could surprise non-expert users.

## How To Report

Preferred:

- Use GitHub's private vulnerability reporting for this repository if it is enabled.

Fallback:

- If private reporting is not available, do not post full exploit details in a public issue.
- Open a minimal issue asking for a private security contact path, without including sensitive payloads, credentials, or proof-of-concept details.

## What To Include

- A short description of the issue
- Impact and realistic attack conditions
- Steps to reproduce
- Affected macOS version
- Whether the issue depends on Codex mode
- Whether the issue requires dangerous full-access mode

## Disclosure Expectations

- Give maintainers a reasonable chance to understand and patch the issue before public disclosure.
- If the issue is low-risk or purely theoretical, say so clearly.
- If the issue can expose local files or execute commands unexpectedly, treat it as high priority.

## Non-Issues

The following are usually not security bugs by themselves:

- The fact that Codex mode is intentionally full-access and unsandboxed
- Requiring users to grant normal macOS permissions such as Microphone, Accessibility, or Input Monitoring

Those are documented project constraints, not hidden vulnerabilities.
