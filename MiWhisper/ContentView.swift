import AppKit
import Charts
import SwiftUI

private struct TranscriptionModeToggle: View {
    @Binding var selection: TranscriptionMode

    var body: some View {
        HStack(spacing: 8) {
            modeButton(.literal)
            modeButton(.translateToEnglish)
        }
    }

    @ViewBuilder
    private func modeButton(_ mode: TranscriptionMode) -> some View {
        Button {
            selection = mode
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(mode.title)
                    .font(.subheadline.weight(.semibold))
                Text(mode == .literal ? "Same language out" : "Always English out")
                    .font(.caption2)
                    .foregroundStyle(selection == mode ? .white.opacity(0.85) : .secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(selection == mode ? Color.accentColor : Color.secondary.opacity(0.12))
            )
            .foregroundStyle(selection == mode ? Color.white : Color.primary)
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(selection == mode ? Color.accentColor : Color.secondary.opacity(0.15), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct WorkspaceChipButton: View {
    let workspace: CodexWorkspaceDescriptor
    let isSelected: Bool
    let threadCount: Int
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(workspace.name)
                        .font(.caption.weight(isSelected ? .semibold : .regular))
                        .lineLimit(1)

                    if isSelected {
                        Text("Selected")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                }

                Text(workspace.path)
                    .font(.caption2)
                    .foregroundStyle(isSelected ? Color.accentColor.opacity(0.9) : .secondary)
                    .lineLimit(1)

                Text("\(threadCount) threads")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(isSelected ? Color.accentColor.opacity(0.9) : .secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 62, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isSelected ? Color.accentColor.opacity(0.55) : Color.secondary.opacity(0.16), lineWidth: 1)
            )
            .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.plain)
        .help(workspace.path)
    }
}

struct ContentView: View {
    private static let selectedCodexWorkspaceIDKey = "miwhisper.codex.selectedWorkspaceID"

    @EnvironmentObject private var appState: AppState
    @ObservedObject private var codexSessionStore = CodexSessionStore.shared
    @ObservedObject private var codexThreadCatalog = CodexThreadCatalog.shared
    @AppStorage(Self.selectedCodexWorkspaceIDKey) private var selectedCodexWorkspaceID = ""
    @State private var selectedStatsPeriod: UsageStatsPeriod = .week

    private var contextualPanelMaxHeight: CGFloat {
        let screen = NSApp.keyWindow?.screen ?? NSScreen.main
        let visibleHeight = screen?.visibleFrame.height ?? 980
        return max(860, visibleHeight - 16)
    }

    private var transcriptHistoryMaxHeight: CGFloat {
        min(420, contextualPanelMaxHeight * 0.34)
    }

    private var codexSessionsMaxHeight: CGFloat {
        min(560, contextualPanelMaxHeight * 0.48)
    }

    private var statsGridColumns: [GridItem] {
        [
            GridItem(.flexible(minimum: 120), spacing: 8),
            GridItem(.flexible(minimum: 120), spacing: 8)
        ]
    }

    private var workspaceGridColumns: [GridItem] {
        [
            GridItem(.flexible(minimum: 0), spacing: 8),
            GridItem(.flexible(minimum: 0), spacing: 8)
        ]
    }

    private var codexWorkspaces: [CodexWorkspaceDescriptor] {
        CodexWorkspaceCatalog.availableWorkspaces(defaultRoot: appState.workspaceRoot)
    }

    private var selectedCodexWorkspace: CodexWorkspaceDescriptor? {
        if let selected = codexWorkspaces.first(where: { $0.id == selectedCodexWorkspaceID }) {
            return selected
        }
        return codexWorkspaces.first(where: \.isDefault) ?? codexWorkspaces.first
    }

    private var filteredCodexEntries: [CodexThreadListEntry] {
        guard let workspace = selectedCodexWorkspace else { return codexThreadCatalog.entries }

        let matchedByPath = codexThreadCatalog.entries.filter { entry in
            codexEntry(entry, belongsTo: workspace)
        }

        if matchedByPath.isEmpty {
            return codexThreadCatalog.entries.filter { entry in
                entry.workspaceName.localizedCaseInsensitiveCompare(workspace.name) == .orderedSame
            }
        }

        return matchedByPath
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("MiWhisper")
                    .font(.headline)

                Text(appState.statusMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Text(appState.permissionSummary)
                    .font(.caption)
                    .foregroundColor(appState.permissionSummary == "Ready" ? .secondary : .orange)

                if !appState.hasAccessibilityAccess {
                    Button("Grant Accessibility") {
                        appState.openAccessibilitySettings()
                        appState.requestAccessibilityPermissionIfNeeded()
                    }
                }

                if !appState.hasInputMonitoringAccess {
                    Button("Grant Input Monitoring for Fn") {
                        appState.openInputMonitoringSettings()
                        appState.requestInputMonitoringPermissionIfNeeded()
                    }
                }

                if !appState.hasNotificationAccess {
                    Text("Notifications missing")
                        .font(.caption)
                        .foregroundColor(.orange)
                }

                if let errorMessage = appState.errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text(URL(fileURLWithPath: appState.currentAppBundlePath).path)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Mode")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    TranscriptionModeToggle(selection: Binding(
                        get: { appState.transcriptionMode },
                        set: { appState.transcriptionMode = $0 }
                    ))

                    Text(appState.transcriptionMode.detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Model")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    ForEach(appState.modelPresets) { preset in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: appState.selectedModelPresetID == preset.id ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(appState.selectedModelPresetID == preset.id ? Color.accentColor : .secondary)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(preset.title)
                                    .foregroundStyle(.primary)
                                Text("\(preset.detail) · \(preset.sizeDescription)")
                                    .font(.caption2)
                                    .foregroundStyle(appState.isModelInstalled(preset) ? Color.secondary : Color.orange)

                                if let downloadStatus = appState.downloadStatusText(for: preset) {
                                    Group {
                                        if let downloadProgress = appState.downloadProgressValue(for: preset) {
                                            ProgressView(value: downloadProgress)
                                                .controlSize(.small)
                                        } else {
                                            ProgressView()
                                                .controlSize(.small)
                                        }
                                    }
                                    .frame(maxWidth: 120, alignment: .leading)

                                    Text(downloadStatus)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()

                            if let _ = appState.downloadStatusText(for: preset) {
                                Text("Downloading")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            } else if appState.isModelInstalled(preset) {
                                Button(appState.selectedModelPresetID == preset.id ? "Selected" : "Use") {
                                    appState.selectModelPreset(preset)
                                }
                                .disabled(appState.selectedModelPresetID == preset.id)
                                .controlSize(.small)
                            } else {
                                Button("Download") {
                                    appState.downloadModelPreset(preset)
                                }
                                .disabled(!appState.canDownload(preset))
                                .controlSize(.small)
                            }
                        }
                    }
                }

                Button(appState.isRecording ? "Stop and Transcribe" : "Start Recording") {
                    appState.toggleRecording()
                }
                .keyboardShortcut(.space, modifiers: [.command, .option])
                .disabled(appState.isTranscribing)

            if !appState.lastTranscript.isEmpty {
                Divider()

                Text("Last Transcript")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(appState.lastTranscript)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)

                Button("Copy Last Transcript") {
                    appState.copyLastTranscript()
                }
            }

            if !appState.transcriptHistory.isEmpty {
                Divider()

                Text("History")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(appState.transcriptHistory.prefix(10)) { entry in
                            Button {
                                appState.copyTranscriptHistoryEntry(entry)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.text)
                                        .lineLimit(2)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    Text(entry.createdAt.formatted(date: .omitted, time: .shortened))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: transcriptHistoryMaxHeight)
            }

            Divider()

            statsSection

            Divider()

            codexSection

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Push to talk: hold Fn")
                Text("Ask Codex: hold Command + Fn")
                Text("Codex opens one window per request")
                Text("Language: \(appState.language)")
                Text("Mode: \(appState.transcriptionMode.title)")
                Text("Model: \(URL(fileURLWithPath: appState.modelPath).lastPathComponent)")
                Text("Codex: \(URL(fileURLWithPath: appState.codexPath).lastPathComponent)")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

                Divider()

                HStack {
                    SettingsLink {
                        Text("Settings")
                    }

                    Spacer()

                    Button("Quit") {
                        NSApplication.shared.terminate(nil)
                    }
                }
            }
            .padding(16)
        }
        .frame(width: 580, height: contextualPanelMaxHeight, alignment: .topLeading)
        .onAppear {
            appState.reloadTranscriptHistory()
            appState.reloadUsageDailyBuckets()
            codexSessionStore.reload()
            normalizeSelectedCodexWorkspace()
            reloadCodexThreadCatalog()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            appState.reloadTranscriptHistory()
            appState.reloadUsageDailyBuckets()
            codexSessionStore.reload()
            normalizeSelectedCodexWorkspace()
            reloadCodexThreadCatalog()
        }
        .onReceive(codexSessionStore.$sessions) { _ in
            reloadCodexThreadCatalog()
        }
        .onChange(of: selectedCodexWorkspaceID) {
            reloadCodexThreadCatalog()
        }
    }

    private var statsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Stats")
                .font(.caption)
                .foregroundStyle(.secondary)

            if appState.hasUsageStats {
                Picker("Stats Period", selection: $selectedStatsPeriod) {
                    ForEach(UsageStatsPeriod.allCases) { period in
                        Text(period.title).tag(period)
                    }
                }
                .pickerStyle(.segmented)

                statsChart

                let snapshot = appState.usageSnapshot(for: selectedStatsPeriod)
                LazyVGrid(columns: statsGridColumns, spacing: 8) {
                    statsCard(title: "Uses", value: "\(snapshot.totalUses)", subtitle: "\(selectedStatsPeriod.title) total")
                    statsCard(title: "Words", value: formattedCount(snapshot.wordCount), subtitle: "Spoken output")
                    statsCard(title: "Dictation", value: "\(snapshot.dictationCount)", subtitle: "Normal insertions")
                    statsCard(title: "Codex", value: "\(snapshot.codexPromptCount)", subtitle: "Voice prompts")
                    statsCard(title: "Spoken Time", value: formatDuration(snapshot.audioSeconds), subtitle: "Recorded audio")
                    statsCard(title: "Saved", value: formatDuration(snapshot.estimatedSavedSeconds), subtitle: "Typing time avoided")
                }

                Text("Saved time is a heuristic: estimated typing time for the words minus actual recorded audio time.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("No usage stats yet. Dictate a few times and MiWhisper will start building daily metrics.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var statsChart: some View {
        let points = appState.usageChartPoints(lastDays: 14)

        return Chart(points) { point in
            BarMark(
                x: .value("Day", point.dayStart, unit: .day),
                y: .value("Saved Minutes", point.savedMinutes)
            )
            .foregroundStyle(Color.accentColor.gradient)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: 2)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(.quaternary)
                AxisValueLabel(format: .dateTime.weekday(.narrow))
                    .font(.caption2)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(.quaternary)
                AxisValueLabel()
                    .font(.caption2)
            }
        }
        .frame(height: 132)
    }

    private var codexSection: some View {
        let entries = filteredCodexEntries
        let workspaceName = selectedCodexWorkspace?.name ?? "selected workspace"

        return VStack(alignment: .leading, spacing: 10) {
            Text("Codex")
                .font(.caption)
                .foregroundStyle(.secondary)

            codexGlobalControls
            codexWorkspaceSummary

            HStack(spacing: 8) {
                Text("Catalog · \(codexThreadCatalog.entries.count) total")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Spacer()

                Button("Reload") {
                    codexSessionStore.reload()
                    normalizeSelectedCodexWorkspace()
                    reloadCodexThreadCatalog()
                }
                .font(.caption2)
                .buttonStyle(.borderless)
            }

            if entries.isEmpty {
                Text("No Codex threads found in \(workspaceName). Catalog has \(codexThreadCatalog.entries.count) total threads.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("Threads · \(workspaceName) · \(entries.count)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(entries) { entry in
                            Button {
                                openCodexThread(entry)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 8) {
                                        Text(entry.title)
                                            .lineLimit(1)
                                            .frame(maxWidth: .infinity, alignment: .leading)

                                        if entry.isBusy {
                                            HStack(spacing: 4) {
                                                ProgressView()
                                                    .controlSize(.small)
                                                Text("Running")
                                                    .font(.caption2)
                                                    .foregroundStyle(.orange)
                                            }
                                        }
                                    }
                                    Text(codexSessionSubtitle(for: entry))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: codexSessionsMaxHeight)
            }
        }
    }

    private var codexWorkspaceSummary: some View {
        return VStack(alignment: .leading, spacing: 6) {
            Text("Workspaces · \(codexWorkspaces.count)")
                .font(.caption2)
                .foregroundStyle(.secondary)

            if let selectedCodexWorkspace {
                Text("Selected · \(selectedCodexWorkspace.name)")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Color.accentColor)
            }

            LazyVGrid(columns: workspaceGridColumns, alignment: .leading, spacing: 8) {
                ForEach(codexWorkspaces) { workspace in
                    WorkspaceChipButton(
                        workspace: workspace,
                        isSelected: selectedCodexWorkspace?.id == workspace.id,
                        threadCount: codexThreadCount(for: workspace),
                        onSelect: {
                            selectCodexWorkspace(workspace.id)
                        }
                    )
                }
            }
        }
    }

    private func normalizeSelectedCodexWorkspace() {
        guard selectedCodexWorkspaceID.isEmpty ||
              codexWorkspaces.contains(where: { $0.id == selectedCodexWorkspaceID }) == false
        else {
            return
        }
        selectedCodexWorkspaceID = codexWorkspaces.first(where: \.isDefault)?.id ?? codexWorkspaces.first?.id ?? ""
    }

    private func selectCodexWorkspace(_ workspaceID: String) {
        selectedCodexWorkspaceID = workspaceID
        reloadCodexThreadCatalog()
    }

    private func reloadCodexThreadCatalog() {
        codexThreadCatalog.reload(workspaces: codexWorkspaces)
    }

    private func codexThreadCount(for workspace: CodexWorkspaceDescriptor) -> Int {
        let matchedByPath = codexThreadCatalog.entries.filter { codexEntry($0, belongsTo: workspace) }
        if matchedByPath.isEmpty {
            return codexThreadCatalog.entries.filter {
                $0.workspaceName.localizedCaseInsensitiveCompare(workspace.name) == .orderedSame
            }.count
        }
        return matchedByPath.count
    }

    private func codexEntry(_ entry: CodexThreadListEntry, belongsTo workspace: CodexWorkspaceDescriptor) -> Bool {
        let entryPath = standardizedCodexPath(entry.workingDirectory)
        let workspacePath = standardizedCodexPath(workspace.path)
        return entryPath == workspacePath || entryPath.hasPrefix(workspacePath + "/")
    }

    private func standardizedCodexPath(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
    }

    private var codexGlobalControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Model")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Picker("Model", selection: Binding(
                        get: { appState.codexDefaultModel },
                        set: { appState.codexDefaultModel = $0 }
                    )) {
                        ForEach(appState.codexModelOptions) { option in
                            Text(option.title).tag(option.id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .frame(width: 132, alignment: .leading)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("Think")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Picker("Think", selection: Binding(
                        get: { appState.codexReasoningEffort },
                        set: { appState.codexReasoningEffort = $0 }
                    )) {
                        ForEach(CodexReasoningEffort.allCases) { effort in
                            Text(effort.title).tag(effort)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .frame(width: 82, alignment: .leading)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("Speed")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Picker("Speed", selection: Binding(
                        get: { appState.codexServiceTier },
                        set: { appState.codexServiceTier = $0 }
                    )) {
                        ForEach(CodexServiceTier.allCases) { tier in
                            Text(tier.title).tag(tier)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .frame(width: 82, alignment: .leading)
                }
            }

            Text("These defaults are applied when you start a new Codex voice session.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func openCodexThread(_ entry: CodexThreadListEntry) {
        if let recordID = entry.recordID {
            CodexSessionManager.shared.openSavedSession(recordID: recordID)
            return
        }

        guard let threadID = entry.threadID else {
            return
        }

        let normalizedModel = appState.codexDefaultModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelOverride = normalizedModel.isEmpty ? nil : normalizedModel

        CodexSessionManager.shared.openThread(
            threadID: threadID,
            title: entry.title,
            workingDirectory: entry.workingDirectory,
            executablePath: appState.codexPath,
            modelOverride: modelOverride,
            reasoningEffort: appState.codexReasoningEffort,
            serviceTier: appState.codexServiceTier
        )
    }

    private func codexSessionSubtitle(for entry: CodexThreadListEntry) -> String {
        let thread = entry.threadID.map { String($0.prefix(8)) } ?? "pending"
        let responsePreview = entry.latestResponse.trimmingCharacters(in: .whitespacesAndNewlines)
        let statusPrefix = entry.isBusy ? "Running" : "Ready"
        let workspacePrefix = entry.workspaceName

        if responsePreview.isEmpty {
            return "\(workspacePrefix) · \(statusPrefix) · Thread \(thread) · \(entry.updatedAt.formatted(date: .omitted, time: .shortened))"
        }

        let compact = responsePreview.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return "\(workspacePrefix) · \(statusPrefix) · \(compact.prefix(70))"
    }

    private func statsCard(title: String, value: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold))
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
        )
    }

    private func formattedCount(_ value: Int) -> String {
        value.formatted(.number.notation(.compactName))
    }

    private func formatDuration(_ seconds: Double) -> String {
        let rounded = max(seconds, 0)
        if rounded < 60 {
            return "\(Int(rounded.rounded()))s"
        }

        if rounded < 3600 {
            return "\(Int((rounded / 60).rounded()))m"
        }

        return String(format: "%.1fh", rounded / 3600.0)
    }
}
