## Summary

- What changed?
- Why?

## Validation

- [ ] `./scripts/smoke-test-whisper.sh`
- [ ] `xcodebuild -project MiWhisper.xcodeproj -scheme MiWhisper -configuration Release -derivedDataPath build CODE_SIGNING_ALLOWED=NO build`
- [ ] Manual check if the change affects dictation, Codex sessions, or rendering

## Docs

- [ ] README updated if behavior changed
- [ ] Other docs updated if needed

## Privacy and Publication Check

- [ ] No personal files or machine-local artifacts included
- [ ] No secrets, private logs, or local-only paths added unintentionally
- [ ] Security-sensitive trade-offs are described honestly
