import SwiftUI

private struct ModelPresetRow: View {
    let preset: WhisperModelPreset
    let isSelected: Bool
    let isInstalled: Bool
    let path: String
    let downloadStatus: String?
    let downloadProgress: Double?
    let canDownload: Bool
    let onSelect: () -> Void
    let onDownload: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(preset.title)
                    .foregroundStyle(.primary)
                Text(path)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Text("\(preset.detail) · \(preset.sizeDescription)")
                    .font(.caption2)
                    .foregroundStyle(isInstalled ? Color.secondary : Color.orange)

                if let downloadStatus {
                    Group {
                        if let downloadProgress {
                            ProgressView(value: downloadProgress)
                                .controlSize(.small)
                        } else {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                    .frame(maxWidth: 180, alignment: .leading)

                    Text(downloadStatus)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()

            if downloadStatus != nil {
                Text("Downloading")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if isInstalled {
                Button(isSelected ? "Selected" : "Use", action: onSelect)
                    .disabled(isSelected)
                    .controlSize(.small)
            } else {
                Button("Download", action: onDownload)
                    .disabled(!canDownload)
                    .controlSize(.small)
            }
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Form {
            Section("General") {
                Toggle(
                    "Launch at login",
                    isOn: Binding(
                        get: { appState.launchAtLoginEnabled },
                        set: { appState.setLaunchAtLogin($0) }
                    )
                )

                Text("Useful for a menu bar utility. This should stay opt-in, not forced.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if appState.launchAtLoginRequiresApproval {
                    Text("macOS requires approval for this login item. Open Login Items in System Settings and enable MiWhisper there.")
                        .font(.caption)
                        .foregroundStyle(.orange)

                    Button("Open Login Items Settings") {
                        appState.openLoginItemsSettings()
                    }
                    .controlSize(.small)
                }

                if let launchAtLoginErrorMessage = appState.launchAtLoginErrorMessage {
                    Text(launchAtLoginErrorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Toggle(
                    "Keep Companion alive after crashes",
                    isOn: Binding(
                        get: { appState.companionWatchdogEnabled },
                        set: { appState.setCompanionWatchdog($0) }
                    )
                )

                Text("Installs a user LaunchAgent that relaunches MiWhisper if it crashes. A normal Quit writes a marker so the watchdog does not reopen it against your intent.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let companionWatchdogErrorMessage = appState.companionWatchdogErrorMessage {
                    Text(companionWatchdogErrorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("Whisper.cpp") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(appState.modelPresets) { preset in
                        ModelPresetRow(
                            preset: preset,
                            isSelected: appState.selectedModelPresetID == preset.id,
                            isInstalled: appState.isModelInstalled(preset),
                            path: appState.path(for: preset),
                            downloadStatus: appState.downloadStatusText(for: preset),
                            downloadProgress: appState.downloadProgressValue(for: preset),
                            canDownload: appState.canDownload(preset)
                        ) {
                            appState.selectModelPreset(preset)
                        } onDownload: {
                            appState.downloadModelPreset(preset)
                        }
                    }
                }

                Divider()

                TextField("CLI path (optional smoke test)", text: $appState.cliPath)
                    .textFieldStyle(.roundedBorder)
                TextField("Model path", text: $appState.modelPath)
                    .textFieldStyle(.roundedBorder)
                TextField("Codex path", text: $appState.codexPath)
                    .textFieldStyle(.roundedBorder)
                TextField("Language", text: $appState.language)
                    .textFieldStyle(.roundedBorder)
                Picker("Mode", selection: Binding(
                    get: { appState.transcriptionMode },
                    set: { appState.transcriptionMode = $0 }
                )) {
                    ForEach(TranscriptionMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                Text(appState.transcriptionMode.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Use ISO language codes such as `es`, `en`, or `auto`. Default is `auto`, which should transcribe literally in the spoken language.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Local whisper.cpp only supports translation into English, not arbitrary target languages.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("The app now transcribes through the embedded whisper.cpp runtime. The CLI path is only kept for the smoke test scripts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Codex sessions now run through `codex app-server` with dangerous full-access mode enabled on purpose for this local internal tool.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Codex Defaults") {
                Picker("Default model", selection: Binding(
                    get: { appState.codexDefaultModel },
                    set: { appState.codexDefaultModel = $0 }
                )) {
                    ForEach(appState.codexModelOptions) { option in
                        Text(option.title).tag(option.id)
                    }
                }

                Picker("Default thinking", selection: Binding(
                    get: { appState.codexReasoningEffort },
                    set: { appState.codexReasoningEffort = $0 }
                )) {
                    ForEach(CodexReasoningEffort.allCases) { effort in
                        Text(effort.title).tag(effort)
                    }
                }

                Picker("Default speed", selection: Binding(
                    get: { appState.codexServiceTier },
                    set: { appState.codexServiceTier = $0 }
                )) {
                    ForEach(CodexServiceTier.allCases) { tier in
                        Text(tier.title).tag(tier)
                    }
                }

                Text("`Model`, `Think`, and `Speed` can all stay on `Default` to respect Codex config.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Session windows can override these values, and those overrides persist in the Codex session history.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Speed is wired to the real app-server service tier values. `Fast` and `Flex` are the actual options Codex currently exposes here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Workspace Defaults") {
                Text(appState.workspaceRoot)
                    .font(.caption)
                    .textSelection(.enabled)
                Button("Reset Paths to Workspace Defaults") {
                    appState.resetPathsToDefaults()
                }
            }

            Section("Mobile Companion") {
                Text("Local bridge")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(CompanionBridge.shared.localURLString)
                    .font(.caption)
                    .textSelection(.enabled)
                Text("Tailnet command")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("tailscale serve --bg --yes 6009")
                    .font(.caption)
                    .textSelection(.enabled)
                Text("Run this manually on the Mac when you want HTTPS for iPhone or iPad. Keep the embedded server on localhost and open the resulting `https://<host>.ts.net` URL from Safari or the iOS wrapper.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Bootstrap") {
                Text("Run `scripts/bootstrap-whispercpp.sh` once to build whisper.cpp static libraries plus the default `small` model.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Use `scripts/download-model.sh <model>` to try stronger models such as `medium` or `large-v3-turbo-q5_0`.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Hotkey") {
                Text("MiWhisper now uses a single hotkey: press and hold `Fn`, release to transcribe and paste.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("For the bridge MVP, press and hold `Command + Fn` to transcribe literally and send that prompt to Codex CLI.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Each Codex request now opens its own window, and each window can continue the same session from the composer at the bottom.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("If `fn` behaves like the Globe key for emoji, dictation, or another system action, macOS may intercept it before the app sees it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("`Command + Fn` is intentionally a best-effort chord on top of the same Fn monitor, so reliability depends on how macOS delivers the Globe/Fn flag sequence on your keyboard.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Paste Fallback") {
                Text("MiWhisper always copies the transcript to the clipboard before trying to paste it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("If there is no target app, focus cannot be restored, or paste fails, you'll get a system notification and the text will stay in the clipboard.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            appState.syncLaunchAtLoginState()
        }
    }
}
