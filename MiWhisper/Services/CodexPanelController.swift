import AppKit
import Combine
import SwiftUI
import WebKit

@MainActor
final class InAppTextInsertionManager {
    struct InsertionContext {
        let precedingCharacter: Character?
        let hasSelection: Bool
    }

    static let shared = InAppTextInsertionManager()

    private weak var activeTextView: NSTextView?

    var hasActiveTarget: Bool {
        resolvedTextView() != nil
    }

    func register(_ textView: NSTextView) {
        activeTextView = textView
    }

    func unregister(_ textView: NSTextView) {
        guard activeTextView === textView else { return }
        activeTextView = nil
    }

    func insertionContext() -> InsertionContext? {
        guard let textView = resolvedTextView() else { return nil }

        let stringValue = textView.string as NSString
        let selection = textView.selectedRange()
        let precedingCharacter: Character?

        if selection.location > 0, selection.location <= stringValue.length {
            precedingCharacter = stringValue.substring(with: NSRange(location: selection.location - 1, length: 1)).first
        } else {
            precedingCharacter = nil
        }

        return InsertionContext(
            precedingCharacter: precedingCharacter,
            hasSelection: selection.length > 0
        )
    }

    @discardableResult
    func insert(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        guard let textView = resolvedTextView(), textView.isEditable else { return false }

        let selectedRange = textView.selectedRange()
        guard textView.shouldChangeText(in: selectedRange, replacementString: text) else {
            return false
        }

        textView.textStorage?.replaceCharacters(in: selectedRange, with: text)
        let insertionLocation = selectedRange.location + (text as NSString).length
        textView.setSelectedRange(NSRange(location: insertionLocation, length: 0))
        textView.didChangeText()
        textView.scrollRangeToVisible(NSRange(location: insertionLocation, length: 0))
        return true
    }

    private func resolvedTextView() -> NSTextView? {
        guard let textView = activeTextView else { return nil }
        guard textView.window?.isKeyWindow == true else { return nil }
        return textView
    }
}

@MainActor
struct CodexSessionRecord: Codable, Identifiable {
    let id: UUID
    var title: String
    var threadID: String?
    var executablePath: String
    var workingDirectory: String
    var modelOverride: String?
    var reasoningEffort: CodexReasoningEffort?
    var serviceTier: CodexServiceTier?
    var accessMode: CodexAccessMode?
    var isBusy: Bool?
    var latestResponse: String
    var activity: [CodexActivityEntry]
    var createdAt: Date
    var updatedAt: Date
}

@MainActor
final class CodexSessionStore: ObservableObject {
    static let shared = CodexSessionStore()

    @Published private(set) var sessions: [CodexSessionRecord] = []

    private static let defaultsKey = "codexSessionHistory"
    private static let maxSessions = 30
    private static let maxActivitiesPerSession = 200

    private let defaults = UserDefaults.standard
    private let fileManager = FileManager.default
    private let maxLatestResponseCharacters = 48_000

    private init() {
        load()
    }

    func createSession(
        title: String,
        executablePath: String,
        workingDirectory: String,
        modelOverride: String?,
        reasoningEffort: CodexReasoningEffort,
        serviceTier: CodexServiceTier,
        accessMode: CodexAccessMode
    ) -> CodexSessionRecord {
        let record = CodexSessionRecord(
            id: UUID(),
            title: title,
            threadID: nil,
            executablePath: executablePath,
            workingDirectory: workingDirectory,
            modelOverride: modelOverride,
            reasoningEffort: reasoningEffort,
            serviceTier: serviceTier,
            accessMode: accessMode,
            isBusy: false,
            latestResponse: "",
            activity: [],
            createdAt: Date(),
            updatedAt: Date()
        )
        upsert(record)
        return record
    }

    func session(id: UUID) -> CodexSessionRecord? {
        sessions.first { $0.id == id }
    }

    func session(threadID: String) -> CodexSessionRecord? {
        sessions.first { $0.threadID == threadID }
    }

    func createImportedThreadSession(
        title: String,
        threadID: String,
        executablePath: String,
        workingDirectory: String,
        modelOverride: String?,
        reasoningEffort: CodexReasoningEffort,
        serviceTier: CodexServiceTier,
        accessMode: CodexAccessMode,
        activity: [CodexActivityEntry] = [],
        latestResponse: String = "",
        createdAt: Date = Date()
    ) -> CodexSessionRecord {
        let record = CodexSessionRecord(
            id: UUID(),
            title: title,
            threadID: threadID,
            executablePath: executablePath,
            workingDirectory: workingDirectory,
            modelOverride: modelOverride,
            reasoningEffort: reasoningEffort,
            serviceTier: serviceTier,
            accessMode: accessMode,
            isBusy: false,
            latestResponse: latestResponse,
            activity: sanitizedActivity(activity),
            createdAt: createdAt,
            updatedAt: Date()
        )
        upsert(record)
        return record
    }

    func updateSession(id: UUID, mutate: (inout CodexSessionRecord) -> Void) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        var record = sessions[index]
        mutate(&record)
        record.activity = sanitizedActivity(record.activity)
        if record.latestResponse.count > maxLatestResponseCharacters {
            record.latestResponse = CodexActivityEntry.clippedText(
                record.latestResponse,
                maxCharacters: maxLatestResponseCharacters
            )
        }
        record.updatedAt = Date()
        sessions[index] = record
        sortAndTrim()
        save()
    }

    private func upsert(_ record: CodexSessionRecord) {
        if let index = sessions.firstIndex(where: { $0.id == record.id }) {
            sessions[index] = record
        } else {
            sessions.insert(record, at: 0)
        }
        sortAndTrim()
        save()
    }

    private func sortAndTrim() {
        sessions.sort { $0.updatedAt > $1.updatedAt }
        if sessions.count > Self.maxSessions {
            sessions = Array(sessions.prefix(Self.maxSessions))
        }
    }

    private func load() {
        let currentBusyState = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0.isBusy ?? false) })
        let loaded = loadStoredSessionData()
        guard let data = loaded.data else {
            sessions = []
            return
        }
        let decodedRecords = decodeSessionRecords(from: data)
        guard !decodedRecords.isEmpty else {
            sessions = []
            return
        }
        let normalizedSessions = decodedRecords
            .map { record in
                var normalized = record
                normalized.isBusy = currentBusyState[normalized.id] ?? false
                normalized.activity = sanitizedActivity(record.activity)
                if normalized.latestResponse.count > maxLatestResponseCharacters {
                    normalized.latestResponse = CodexActivityEntry.clippedText(
                        normalized.latestResponse,
                        maxCharacters: maxLatestResponseCharacters
                    )
                }
                return normalized
            }
            .sorted { $0.updatedAt > $1.updatedAt }

        sessions = normalizedSessions

        if let normalizedData = try? JSONEncoder().encode(normalizedSessions), normalizedData != data {
            save()
        } else if loaded.source == .defaults {
            save()
        }
    }

    func reload() {
        load()
    }

    func deleteSession(id: UUID) {
        sessions.removeAll { $0.id == id }
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(sessions) else { return }
        do {
            let url = sessionHistoryFileURL()
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
            if defaults.object(forKey: Self.defaultsKey) != nil {
                defaults.removeObject(forKey: Self.defaultsKey)
            }
        } catch {
            NSLog("[MiWhisper][CodexSessionStore] failed to save session history file error=%@", error.localizedDescription)
            if data.count < 3_500_000 {
                defaults.set(data, forKey: Self.defaultsKey)
            }
        }
    }

    private enum StorageSource {
        case file
        case defaults
    }

    private func loadStoredSessionData() -> (data: Data?, source: StorageSource?) {
        let url = sessionHistoryFileURL()
        if let fileData = try? Data(contentsOf: url) {
            return (fileData, .file)
        }
        if let defaultsData = defaults.data(forKey: Self.defaultsKey) {
            return (defaultsData, .defaults)
        }
        return (nil, nil)
    }

    private func sessionHistoryFileURL() -> URL {
        let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return baseURL
            .appendingPathComponent("MiWhisper", isDirectory: true)
            .appendingPathComponent("codex-session-history.json", isDirectory: false)
    }

    private func decodeSessionRecords(from data: Data) -> [CodexSessionRecord] {
        if let direct = try? JSONDecoder().decode([CodexSessionRecord].self, from: data) {
            return direct
        }

        if let lossy = try? JSONDecoder().decode([LossyDecodable<CodexSessionRecord>].self, from: data) {
            let recovered = lossy.compactMap(\.value)
            NSLog("[MiWhisper][CodexSessionStore] recovered %ld session(s) via lossy decode", recovered.count)
            return recovered
        }

        NSLog("[MiWhisper][CodexSessionStore] failed to decode saved Codex session history")
        return []
    }

    private func sanitizedActivity(_ activity: [CodexActivityEntry]) -> [CodexActivityEntry] {
        Array(activity.suffix(Self.maxActivitiesPerSession)).map { $0.sanitizedForStorage() }
    }
}

private struct LossyDecodable<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        value = try? container.decode(Value.self)
    }
}

private enum CodexSessionTitleBuilder {
    static func make(for prompt: String) -> String {
        let collapsed = prompt.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return "Codex • " + String(collapsed.prefix(40))
    }
}

@MainActor
private enum CodexModelCatalog {
    static func options(currentModel: String) -> [CodexModelOption] {
        var options = AppState.shared.codexModelOptions
        let normalized = currentModel.trimmingCharacters(in: .whitespacesAndNewlines)

        if !normalized.isEmpty, !options.contains(where: { $0.id == normalized }) {
            options.insert(CodexModelOption(id: normalized, title: "Saved: \(normalized)"), at: 1)
        }

        return options
    }
}

private struct CodexNativeThreadHistory {
    let activity: [CodexActivityEntry]
    let latestResponse: String
    let createdAt: Date

    static func load(threadID: String) -> CodexNativeThreadHistory? {
        guard let fileURL = sessionFileURL(for: threadID) else { return nil }

        var activity: [CodexActivityEntry] = []
        var seenMessages: Set<String> = []
        var latestResponse = ""
        var createdAt: Date?

        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? handle.close() }

        let data = handle.readDataToEndOfFile()
        guard let contents = String(data: data, encoding: .utf8) else { return nil }

        for line in contents.split(whereSeparator: \.isNewline) {
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                continue
            }

            let topType = object["type"] as? String
            let payload = object["payload"] as? [String: Any] ?? [:]
            let payloadType = payload["type"] as? String
            let role = payload["role"] as? String
            let entryDate = date(from: object["timestamp"] as? String ?? payload["timestamp"] as? String)
            createdAt = min(createdAt ?? entryDate, entryDate)

            switch (topType, payloadType, role) {
            case ("event_msg", "user_message", _):
                guard let message = cleanedUserMessage(payload["message"] as? String),
                      seenMessages.insert("user:\(message)").inserted
                else {
                    continue
                }
                activity.append(
                    CodexActivityEntry(
                        kind: .user,
                        blockKind: .system,
                        title: "User",
                        detail: CodexActivityEntry.clippedText(message, maxCharacters: 12_000),
                        createdAt: entryDate
                    )
                )

            case ("event_msg", "agent_reasoning", _):
                guard let text = nonEmpty(payload["text"] as? String) else { continue }
                activity.append(
                    CodexActivityEntry(
                        kind: .assistant,
                        blockKind: .reasoning,
                        title: "Thinking",
                        detail: CodexActivityEntry.clippedText(text, maxCharacters: 8_000),
                        createdAt: entryDate
                    )
                )

            case ("event_msg", "agent_message", _):
                guard let message = nonEmpty(payload["message"] as? String),
                      seenMessages.insert("assistant:\(message)").inserted
                else {
                    continue
                }
                latestResponse = message
                activity.append(
                    CodexActivityEntry(
                        kind: .assistant,
                        blockKind: .final,
                        title: "Codex",
                        detail: CodexActivityEntry.clippedText(message, maxCharacters: 16_000),
                        relatedFiles: relatedFiles(in: message),
                        createdAt: entryDate
                    )
                )

            case ("response_item", "message", "user"):
                guard let message = cleanedUserMessage(contentText(from: payload)),
                      seenMessages.insert("user:\(message)").inserted
                else {
                    continue
                }
                activity.append(
                    CodexActivityEntry(
                        kind: .user,
                        blockKind: .system,
                        title: "User",
                        detail: CodexActivityEntry.clippedText(message, maxCharacters: 12_000),
                        createdAt: entryDate
                    )
                )

            case ("response_item", "message", "assistant"):
                guard let message = nonEmpty(contentText(from: payload)),
                      seenMessages.insert("assistant:\(message)").inserted
                else {
                    continue
                }
                latestResponse = message
                activity.append(
                    CodexActivityEntry(
                        kind: .assistant,
                        blockKind: .final,
                        title: "Codex",
                        detail: CodexActivityEntry.clippedText(message, maxCharacters: 16_000),
                        relatedFiles: relatedFiles(in: message),
                        createdAt: entryDate
                    )
                )

            case ("response_item", "function_call", _), ("response_item", "custom_tool_call", _):
                let name = payload["name"] as? String ?? "tool"
                let arguments = payload["arguments"] as? String ?? payload["input"] as? String ?? ""
                let command = commandText(toolName: name, arguments: arguments)
                activity.append(
                    CodexActivityEntry(
                        kind: .tool,
                        blockKind: command == nil ? .tool : .command,
                        title: command == nil ? "Tool Call: \(name)" : "Command",
                        detail: CodexActivityEntry.clippedText(arguments, maxCharacters: 8_000),
                        detailStyle: .monospaced,
                        command: command,
                        relatedFiles: relatedFiles(in: arguments),
                        createdAt: entryDate
                    )
                )

            case ("response_item", "function_call_output", _), ("response_item", "custom_tool_call_output", _):
                guard let output = nonEmpty(payload["output"] as? String) else { continue }
                activity.append(
                    CodexActivityEntry(
                        kind: .tool,
                        blockKind: .tool,
                        title: "Tool Output",
                        detail: CodexActivityEntry.clippedText(output, maxCharacters: 10_000),
                        detailStyle: .monospaced,
                        relatedFiles: relatedFiles(in: output),
                        createdAt: entryDate
                    )
                )

            default:
                continue
            }
        }

        guard !activity.isEmpty else { return nil }

        let storedActivity = Array(activity.suffix(200)).map { $0.sanitizedForStorage() }
        return CodexNativeThreadHistory(
            activity: storedActivity,
            latestResponse: CodexActivityEntry.clippedText(latestResponse, maxCharacters: 48_000),
            createdAt: createdAt ?? storedActivity.first?.createdAt ?? Date()
        )
    }

    private static func sessionFileURL(for threadID: String) -> URL? {
        let sessionsRootURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/sessions")
        guard let enumerator = FileManager.default.enumerator(
            at: sessionsRootURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        var fallbackMatches: [URL] = []
        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "jsonl" else { continue }
            if fileURL.lastPathComponent.contains(threadID) {
                return fileURL
            }
            fallbackMatches.append(fileURL)
        }

        return fallbackMatches.first { containsSessionID(threadID, at: $0) }
    }

    private static func containsSessionID(_ threadID: String, at fileURL: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return false }
        defer { try? handle.close() }

        guard let data = try? handle.read(upToCount: 4096),
              let contents = String(data: data, encoding: .utf8),
              let firstLine = contents.split(whereSeparator: \.isNewline).first,
              let jsonData = String(firstLine).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let payload = object["payload"] as? [String: Any],
              let sessionID = payload["id"] as? String
        else {
            return false
        }

        return sessionID == threadID
    }

    private static func cleanedUserMessage(_ rawMessage: String?) -> String? {
        guard var message = nonEmpty(rawMessage) else { return nil }

        if let range = message.range(of: "## My request for Codex:") {
            message = String(message[range.upperBound...])
        }

        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard !trimmed.hasPrefix("# AGENTS.md instructions") else { return nil }
        guard !trimmed.hasPrefix("<environment_context>") else { return nil }
        guard !trimmed.hasPrefix("Generate a concise UI title") else { return nil }
        return trimmed
    }

    private static func contentText(from payload: [String: Any]) -> String? {
        if let text = payload["text"] as? String {
            return text
        }

        guard let content = payload["content"] as? [[String: Any]] else {
            return nil
        }

        let parts = content.compactMap { item -> String? in
            if let text = item["text"] as? String {
                return text
            }
            return item["content"] as? String
        }

        return nonEmpty(parts.joined(separator: "\n\n"))
    }

    private static func commandText(toolName: String, arguments: String) -> String? {
        guard toolName == "shell_command" || toolName == "exec_command" else { return nil }
        guard let data = arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nonEmpty(arguments)
        }

        if let command = object["command"] as? String {
            return command
        }
        if let cmd = object["cmd"] as? String {
            return cmd
        }
        if let cmd = object["cmd"] as? [String] {
            return cmd.joined(separator: " ")
        }
        return nil
    }

    private static func relatedFiles(in text: String) -> [CodexActivityFile] {
        ActivityFileReferenceParser.paths(in: text).map { CodexActivityFile(path: $0) }
    }

    private static func nonEmpty(_ text: String?) -> String? {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func date(from rawValue: String?) -> Date {
        guard let rawValue else { return Date() }
        return fractionalDateFormatter.date(from: rawValue)
            ?? plainDateFormatter.date(from: rawValue)
            ?? Date()
    }

    private static let fractionalDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plainDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

private func codexActivityHistoryMatches(_ lhs: [CodexActivityEntry], _ rhs: [CodexActivityEntry]) -> Bool {
    guard lhs.count == rhs.count else { return false }

    for (left, right) in zip(lhs, rhs) {
        guard left.kind == right.kind,
              left.blockKind == right.blockKind,
              left.title == right.title,
              left.detail == right.detail,
              left.detailStyle == right.detailStyle,
              left.command == right.command,
              left.relatedFiles == right.relatedFiles,
              abs(left.createdAt.timeIntervalSince(right.createdAt)) < 0.001
        else {
            return false
        }
    }

    return true
}

@MainActor
final class CodexSessionManager {
    static let shared = CodexSessionManager()

    private var models: [UUID: CodexSessionViewModel] = [:]
    private var controllers: [UUID: CodexSessionWindowController] = [:]

    func openSession(
        prompt: String,
        executablePath: String,
        workingDirectory: String,
        modelOverride: String?,
        reasoningEffort: CodexReasoningEffort,
        serviceTier: CodexServiceTier,
        accessMode: CodexAccessMode = .fullAccess
    ) {
        let sessionID = createSession(
            prompt: prompt,
            executablePath: executablePath,
            workingDirectory: workingDirectory,
            modelOverride: modelOverride,
            reasoningEffort: reasoningEffort,
            serviceTier: serviceTier,
            accessMode: accessMode,
            shouldPresentWindow: true
        )
        guard let model = models[sessionID] else { return }
        model.startInitialTurn(prompt: prompt)
    }

    @discardableResult
    func createSession(
        prompt: String,
        executablePath: String,
        workingDirectory: String,
        modelOverride: String?,
        reasoningEffort: CodexReasoningEffort,
        serviceTier: CodexServiceTier,
        accessMode: CodexAccessMode = .fullAccess,
        shouldPresentWindow: Bool
    ) -> UUID {
        let title = CodexSessionTitleBuilder.make(for: prompt)
        let record = CodexSessionStore.shared.createSession(
            title: title,
            executablePath: executablePath,
            workingDirectory: workingDirectory,
            modelOverride: modelOverride,
            reasoningEffort: reasoningEffort,
            serviceTier: serviceTier,
            accessMode: accessMode
        )
        let model = CodexSessionViewModel(record: record)
        models[model.id] = model

        if shouldPresentWindow {
            presentWindow(for: model)
        }

        return model.id
    }

    func openSavedSession(recordID: UUID) {
        if let controller = controllers[recordID] {
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let model: CodexSessionViewModel
        if let existingModel = models[recordID] {
            model = existingModel
        } else {
            guard let record = CodexSessionStore.shared.session(id: recordID) else { return }
            let newModel = CodexSessionViewModel(record: record)
            models[recordID] = newModel
            model = newModel
        }

        presentWindow(for: model)
    }

    @discardableResult
    func openThread(
        threadID: String,
        title: String,
        workingDirectory: String,
        executablePath: String,
        modelOverride: String?,
        reasoningEffort: CodexReasoningEffort,
        serviceTier: CodexServiceTier,
        accessMode: CodexAccessMode = .fullAccess
    ) -> UUID {
        if let existingRecord = CodexSessionStore.shared.session(threadID: threadID) {
            hydrateNativeThreadIfNeeded(existingRecord)
            openSavedSession(recordID: existingRecord.id)
            return existingRecord.id
        }

        let history = CodexNativeThreadHistory.load(threadID: threadID)
        let record = CodexSessionStore.shared.createImportedThreadSession(
            title: title,
            threadID: threadID,
            executablePath: executablePath,
            workingDirectory: workingDirectory,
            modelOverride: modelOverride,
            reasoningEffort: reasoningEffort,
            serviceTier: serviceTier,
            accessMode: accessMode,
            activity: history?.activity ?? [],
            latestResponse: history?.latestResponse ?? "",
            createdAt: history?.createdAt ?? Date()
        )
        let model = CodexSessionViewModel(record: record)
        models[model.id] = model
        presentWindow(for: model)
        return model.id
    }

    func sessionRecord(id: UUID) -> CodexSessionRecord? {
        CodexSessionStore.shared.session(id: id)
    }

    func hydrateSavedThreadIfNeeded(recordID: UUID) {
        guard let record = CodexSessionStore.shared.session(id: recordID) else { return }
        hydrateNativeThreadIfNeeded(record)
    }

    func allSessionRecords() -> [CodexSessionRecord] {
        CodexSessionStore.shared.sessions
    }

    func send(
        prompt: String,
        to recordID: UUID,
        reasoningEffort: CodexReasoningEffort? = nil,
        serviceTier: CodexServiceTier? = nil,
        accessMode: CodexAccessMode? = nil,
        attachments: [CodexTurnAttachment] = []
    ) throws {
        guard let model = model(for: recordID) else {
            throw CodexRunnerError.missingThread
        }
        try model.sendPromptFromBridge(
            prompt,
            reasoningEffort: reasoningEffort,
            serviceTier: serviceTier,
            accessMode: accessMode,
            attachments: attachments
        )
    }

    func stop(recordID: UUID) {
        guard let model = model(for: recordID) else { return }
        model.stopCurrentTurn()
    }

    func resolveApproval(recordID: UUID, requestID: Int, decision: String) throws {
        guard let model = model(for: recordID) else {
            throw CodexRunnerError.missingThread
        }
        try model.resolveApproval(requestID: requestID, decision: decision)
    }

    func focus(recordID: UUID) {
        openSavedSession(recordID: recordID)
    }

    private func model(for recordID: UUID) -> CodexSessionViewModel? {
        if let existingModel = models[recordID] {
            return existingModel
        }

        guard let record = CodexSessionStore.shared.session(id: recordID) else {
            return nil
        }

        let model = CodexSessionViewModel(record: record)
        models[recordID] = model
        return model
    }

    private func presentWindow(for model: CodexSessionViewModel) {
        let controller = CodexSessionWindowController(model: model) { [weak self] sessionID in
            self?.controllers.removeValue(forKey: sessionID)
        }

        controllers[model.id] = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func hydrateNativeThreadIfNeeded(_ record: CodexSessionRecord) {
        guard record.isBusy != true,
              models[record.id]?.isBusy != true,
              let threadID = record.threadID,
              let history = CodexNativeThreadHistory.load(threadID: threadID)
        else {
            return
        }

        let historyCanRefreshActivity = record.activity.isEmpty || history.activity.count >= record.activity.count
        let activityNeedsRefresh = historyCanRefreshActivity && !codexActivityHistoryMatches(record.activity, history.activity)
        let importedLatestResponse = history.latestResponse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? CodexSessionViewModel.derivedLatestResponse(from: history.activity)
            : history.latestResponse
        let latestNeedsRefresh = record.latestResponse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !importedLatestResponse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        guard activityNeedsRefresh || latestNeedsRefresh else {
            return
        }

        CodexSessionStore.shared.updateSession(id: record.id) { storedRecord in
            if activityNeedsRefresh {
                storedRecord.activity = history.activity
            }
            if activityNeedsRefresh || storedRecord.latestResponse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                storedRecord.latestResponse = importedLatestResponse
            }
            storedRecord.createdAt = min(storedRecord.createdAt, history.createdAt)
        }

        models[record.id]?.refreshHistoryIfChanged(
            activity: history.activity,
            latestResponse: importedLatestResponse
        )
    }
}

@MainActor
final class CodexReaderWindowManager {
    static let shared = CodexReaderWindowManager()

    private var controllers: [UUID: CodexReaderWindowController] = [:]

    func openReader(title: String, response: String) {
        let model = CodexReaderViewModel(title: title, document: ReaderDocument(kind: .response(response)))
        present(model)
    }

    func openFileReader(path: String) {
        let fileURL = URL(fileURLWithPath: path)
        guard let document = renderedDocument(for: fileURL) else {
            NSWorkspace.shared.open(fileURL)
            return
        }

        let model = CodexReaderViewModel(title: fileURL.lastPathComponent, document: document)
        present(model)
    }

    private func present(_ model: CodexReaderViewModel) {
        let controller = CodexReaderWindowController(model: model) { [weak self] readerID in
            self?.controllers.removeValue(forKey: readerID)
        }

        controllers[model.id] = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func renderedDocument(for fileURL: URL) -> ReaderDocument? {
        guard let fileType = ReaderRenderableFileType(url: fileURL) else { return nil }
        guard let body = try? String(contentsOf: fileURL, encoding: .utf8) else { return nil }

        switch fileType {
        case .html:
            return ReaderDocument(
                kind: .file(
                    path: fileURL.path,
                    body: body,
                    baseURL: fileURL.deletingLastPathComponent()
                )
            )
        case .markdown:
            return ReaderDocument(
                kind: .file(
                    path: fileURL.path,
                    body: body,
                    baseURL: nil
                )
            )
        }
    }
}

@MainActor
final class CodexSessionWindowController: NSWindowController, NSWindowDelegate {
    private let model: CodexSessionViewModel
    private let onClose: (UUID) -> Void
    private var cancellables: Set<AnyCancellable> = []

    init(model: CodexSessionViewModel, onClose: @escaping (UUID) -> Void) {
        self.model = model
        self.onClose = onClose

        let contentView = CodexSessionView(model: model)
        let hostingController = NSHostingController(rootView: contentView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = model.windowTitle
        window.titlebarAppearsTransparent = false
        window.isReleasedWhenClosed = false
        window.contentViewController = hostingController

        super.init(window: window)

        window.delegate = self

        model.$windowTitle
            .receive(on: RunLoop.main)
            .sink { [weak window] title in
                window?.title = title
            }
            .store(in: &cancellables)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func windowWillClose(_ notification: Notification) {
        onClose(model.id)
    }
}

@MainActor
final class CodexReaderWindowController: NSWindowController, NSWindowDelegate {
    private let model: CodexReaderViewModel
    private let onClose: (UUID) -> Void
    private var cancellables: Set<AnyCancellable> = []

    init(model: CodexReaderViewModel, onClose: @escaping (UUID) -> Void) {
        self.model = model
        self.onClose = onClose

        let contentView = CodexReaderWindowView(model: model)
        let hostingController = NSHostingController(rootView: contentView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = model.title
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unifiedCompact
        window.isReleasedWhenClosed = false
        window.contentViewController = hostingController

        super.init(window: window)

        window.delegate = self

        model.$title
            .receive(on: RunLoop.main)
            .sink { [weak window] title in
                window?.title = title
            }
            .store(in: &cancellables)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func windowWillClose(_ notification: Notification) {
        onClose(model.id)
    }
}

@MainActor
final class CodexSessionViewModel: ObservableObject {
    private static let maxActivityEntries = 160
    private static let maxVisibleActivityEntries = 120

    let id: UUID

    @Published var windowTitle = "Codex Session"
    @Published var threadID: String?
    @Published var status = "Ready"
    @Published var composerText = ""
    @Published var latestResponse = ""
    @Published var activity: [CodexActivityEntry] = []
    @Published var isBusy = false
    @Published var modelOverride = "" {
        didSet {
            guard oldValue != modelOverride else { return }
            syncSessionRecord()
        }
    }
    @Published var reasoningEffort: CodexReasoningEffort = .useConfigDefault {
        didSet {
            guard oldValue != reasoningEffort else { return }
            syncSessionRecord()
        }
    }
    @Published var serviceTier: CodexServiceTier = .useConfigDefault {
        didSet {
            guard oldValue != serviceTier else { return }
            syncSessionRecord()
        }
    }
    @Published var accessMode: CodexAccessMode = .fullAccess {
        didSet {
            guard oldValue != accessMode else { return }
            syncSessionRecord()
        }
    }

    private let runner: CodexRunner
    private let executablePath: String
    private let workingDirectory: String
    private var persistTask: Task<Void, Never>?

    init(record: CodexSessionRecord) {
        id = record.id
        windowTitle = record.title
        threadID = record.threadID
        latestResponse = record.latestResponse
        activity = record.activity
        modelOverride = record.modelOverride ?? ""
        reasoningEffort = record.reasoningEffort ?? .useConfigDefault
        serviceTier = record.serviceTier ?? .useConfigDefault
        accessMode = record.accessMode ?? .fullAccess
        executablePath = record.executablePath
        workingDirectory = record.workingDirectory
        runner = CodexRunner(
            executablePath: record.executablePath,
            workingDirectory: record.workingDirectory,
            initialThreadID: record.threadID
        )
        if latestResponse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            latestResponse = Self.derivedLatestResponse(from: activity)
        }
        bindRunner()
    }

    func startInitialTurn(prompt: String) {
        send(prompt: prompt)
    }

    func sendComposerText() {
        let prompt = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        composerText = ""
        send(prompt: prompt)
    }

    func close() {
        runner.cancel()
    }

    func stopCurrentTurn() {
        runner.cancel()
    }

    func sendPromptFromBridge(
        _ prompt: String,
        reasoningEffort: CodexReasoningEffort? = nil,
        serviceTier: CodexServiceTier? = nil,
        accessMode: CodexAccessMode? = nil,
        attachments: [CodexTurnAttachment] = []
    ) throws {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else {
            throw CodexRunnerError.emptyPrompt
        }
        send(
            prompt: trimmedPrompt,
            reasoningEffort: reasoningEffort,
            serviceTier: serviceTier,
            accessMode: accessMode,
            attachments: attachments
        )
    }

    func resolveApproval(requestID: Int, decision: String) throws {
        try runner.resolveServerRequest(requestID: requestID, decision: decision)
    }

    func hydrateHistoryIfNeeded(activity importedActivity: [CodexActivityEntry], latestResponse importedLatestResponse: String) {
        guard activity.isEmpty, !importedActivity.isEmpty else { return }

        activity = importedActivity
        if latestResponse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            latestResponse = importedLatestResponse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? Self.derivedLatestResponse(from: importedActivity)
                : importedLatestResponse
        }
        trimActivity()
        requestPersist(immediate: true)
    }

    func refreshHistoryIfChanged(activity importedActivity: [CodexActivityEntry], latestResponse importedLatestResponse: String) {
        guard !isBusy else { return }

        var changed = false
        if !importedActivity.isEmpty && !codexActivityHistoryMatches(activity, importedActivity) {
            activity = importedActivity
            changed = true
        }

        let resolvedLatestResponse = importedLatestResponse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? Self.derivedLatestResponse(from: importedActivity)
            : importedLatestResponse
        if !resolvedLatestResponse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            (changed || latestResponse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
            latestResponse = resolvedLatestResponse
            changed = true
        }

        guard changed else { return }
        trimActivity()
        requestPersist(immediate: true)
    }

    var sessionWorkingDirectory: String {
        workingDirectory
    }

    func openReader() {
        let trimmedResponse = latestResponse.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedResponse.isEmpty else { return }

        let title: String
        if let threadID {
            title = "Codex Reader • \(threadID.prefix(8))"
        } else {
            title = "Codex Reader"
        }

        CodexReaderWindowManager.shared.openReader(title: title, response: trimmedResponse)
    }

    var visibleActivity: [CodexActivityEntry] {
        Array(activity.suffix(Self.maxVisibleActivityEntries))
    }

    fileprivate var visibleBlocks: [CodexActivityBlock] {
        CodexActivityBlock.make(from: visibleActivity)
    }

    var hiddenActivityCount: Int {
        max(0, activity.count - visibleActivity.count)
    }

    private func bindRunner() {
        runner.onActivity = { [weak self] entry in
            guard let self else { return }
            if
                let sourceID = entry.sourceID,
                let index = self.activity.lastIndex(where: { $0.sourceID == sourceID })
            {
                let existing = self.activity[index]
                let replacement = CodexActivityEntry(
                    id: existing.id,
                    sourceID: entry.sourceID,
                    groupID: entry.groupID ?? existing.groupID,
                    kind: entry.kind,
                    blockKind: entry.blockKind,
                    title: entry.title,
                    detail: entry.detail,
                    detailStyle: entry.detailStyle,
                    command: entry.command,
                    relatedFiles: entry.relatedFiles,
                    createdAt: existing.createdAt
                )
                self.activity[index] = replacement
            } else {
                self.activity.append(entry)
            }
            self.refreshLatestResponseIfNeeded(from: entry)
            self.trimActivity()
            self.requestPersist()
        }

        runner.onStateChange = { [weak self] running in
            guard let self else { return }
            self.isBusy = running
            if running {
                self.status = "Running Codex..."
            }
            self.requestPersist(immediate: true)
        }

        runner.onThreadID = { [weak self] threadID in
            guard let self else { return }
            self.threadID = threadID
            self.windowTitle = "Codex • \(threadID.prefix(8))"
            self.status = "Session \(threadID)"
            self.requestPersist(immediate: true)
        }

        runner.onTurnCompleted = { [weak self] result in
            guard let self else { return }
            self.latestResponse = result.response
            self.status = result.sessionID.map { "Ready • \($0)" } ?? "Ready"
            self.requestPersist(immediate: true)
        }

        runner.onTurnFailed = { [weak self] message in
            guard let self else { return }
            self.status = "Codex failed"
            self.activity.append(
                CodexActivityEntry(
                    kind: .error,
                    title: "Turn Failed",
                    detail: message
                )
            )
            self.trimActivity()
            self.requestPersist(immediate: true)
        }

        runner.onTurnInterrupted = { [weak self] message in
            guard let self else { return }
            self.status = message
            self.activity.append(
                CodexActivityEntry(
                    kind: .warning,
                    title: "Turn Interrupted",
                    detail: "The current Codex turn was stopped by the user."
                )
            )
            self.trimActivity()
            self.requestPersist(immediate: true)
        }
    }

    private func send(
        prompt: String,
        reasoningEffort overrideReasoningEffort: CodexReasoningEffort? = nil,
        serviceTier overrideServiceTier: CodexServiceTier? = nil,
        accessMode overrideAccessMode: CodexAccessMode? = nil,
        attachments: [CodexTurnAttachment] = []
    ) {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else { return }

        let turnReasoningEffort = overrideReasoningEffort ?? reasoningEffort
        let turnServiceTier = overrideServiceTier ?? serviceTier
        let turnAccessMode = overrideAccessMode ?? accessMode

        do {
            if isBusy {
                try runner.steer(prompt: trimmedPrompt, attachments: attachments)
                return
            }

            if let overrideReasoningEffort {
                reasoningEffort = overrideReasoningEffort
            }
            if let overrideServiceTier {
                serviceTier = overrideServiceTier
            }
            if let overrideAccessMode {
                accessMode = overrideAccessMode
            }

            if let threadID {
                try runner.run(
                    command: .resume(
                        sessionID: threadID,
                        prompt: trimmedPrompt,
                        modelOverride: modelOverride,
                        reasoningEffort: turnReasoningEffort,
                        serviceTier: turnServiceTier,
                        accessMode: turnAccessMode,
                        attachments: attachments
                    )
                )
            } else {
                windowTitle = CodexSessionTitleBuilder.make(for: trimmedPrompt)
                requestPersist(immediate: true)
                try runner.run(
                    command: .start(
                        prompt: trimmedPrompt,
                        modelOverride: modelOverride,
                        reasoningEffort: turnReasoningEffort,
                        serviceTier: turnServiceTier,
                        accessMode: turnAccessMode,
                        attachments: attachments
                    )
                )
            }
        } catch {
            status = "Codex failed"
            activity.append(
                CodexActivityEntry(
                    kind: .error,
                    title: "Launch Failed",
                    detail: error.localizedDescription
                )
            )
            trimActivity()
            requestPersist(immediate: true)
        }
    }

    private func trimActivity() {
        if activity.count > Self.maxActivityEntries {
            activity = Array(activity.suffix(Self.maxActivityEntries))
        }
    }

    private func refreshLatestResponseIfNeeded(from entry: CodexActivityEntry) {
        guard entry.blockKind == .final else { return }

        let trimmedDetail = entry.detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedDetail.isEmpty else { return }

        latestResponse = trimmedDetail
    }

    private func requestPersist(immediate: Bool = false) {
        persistTask?.cancel()

        if immediate {
            syncSessionRecord()
            return
        }

        persistTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard let self, !Task.isCancelled else { return }
            self.syncSessionRecord()
        }
    }

    private func syncSessionRecord() {
        CodexSessionStore.shared.updateSession(id: id) { record in
            record.title = windowTitle
            record.threadID = threadID
            record.latestResponse = latestResponse
            record.activity = activity
            record.executablePath = executablePath
            record.workingDirectory = workingDirectory
            record.modelOverride = modelOverride.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : modelOverride
            record.reasoningEffort = reasoningEffort
            record.serviceTier = serviceTier
            record.accessMode = accessMode
            record.isBusy = isBusy
        }
    }

    fileprivate static func derivedLatestResponse(from activity: [CodexActivityEntry]) -> String {
        activity
            .reversed()
            .first {
                $0.blockKind == .final &&
                !($0.detail?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            }?
            .detail?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

@MainActor
final class CodexReaderViewModel: ObservableObject {
    let id = UUID()

    @Published var title: String
    @Published var document: ReaderDocument

    init(title: String, document: ReaderDocument) {
        self.title = title
        self.document = document
    }
}

struct ReaderDocument {
    enum Kind {
        case response(String)
        case file(path: String, body: String, baseURL: URL?)
    }

    let kind: Kind

    var body: String {
        switch kind {
        case let .response(text):
            return text
        case let .file(_, body, _):
            return body
        }
    }

    var filePath: String? {
        switch kind {
        case .response:
            return nil
        case let .file(path, _, _):
            return path
        }
    }

    var baseURL: URL? {
        switch kind {
        case .response:
            return nil
        case let .file(_, _, baseURL):
            return baseURL
        }
    }
}

@MainActor
private struct CodexActivityBlock: Identifiable {
    let id: String
    let kind: CodexActivityBlockKind
    let entries: [CodexActivityEntry]

    var createdAt: Date { entries.first?.createdAt ?? .now }
    var updatedAt: Date { entries.last?.createdAt ?? createdAt }
    var latestEntry: CodexActivityEntry { entries.last! }

    var title: String {
        switch kind {
        case .command:
            return latestEntry.title.contains("Completed") ? "Command" : latestEntry.title
        case .tool:
            return "Tool"
        case .patch:
            return "Patch"
        case .reasoning:
            return latestEntry.title
        case .final:
            return "Final"
        case .system:
            return latestEntry.title
        }
    }

    var command: String? {
        entries.compactMap(\.command).last
    }

    var detail: String? {
        entries.reversed().compactMap(\.detail).first(where: { !$0.isEmpty })
    }

    var relatedFiles: [CodexActivityFile] {
        var ordered: [CodexActivityFile] = []
        var seen: Set<String> = []

        for entry in entries {
            for file in entry.relatedFiles where !seen.contains(file.id) {
                ordered.append(file)
                seen.insert(file.id)
            }
        }

        return ordered
    }

    var referencedFilePaths: [String] {
        ActivityFileReferenceParser.paths(in: entries.compactMap(\.detail).joined(separator: "\n\n"))
    }

    var summary: String? {
        switch kind {
        case .command:
            if let detail {
                return detail
            }
            return latestEntry.title
        case .tool, .reasoning, .patch, .final, .system:
            return detail
        }
    }

    static func make(from entries: [CodexActivityEntry]) -> [CodexActivityBlock] {
        var order: [String] = []
        var grouped: [String: [CodexActivityEntry]] = [:]

        for entry in entries {
            let key = entry.groupID ?? entry.sourceID ?? entry.id.uuidString
            if grouped[key] == nil {
                order.append(key)
                grouped[key] = []
            }
            grouped[key, default: []].append(entry)
        }

        return order.compactMap { key in
            guard let entries = grouped[key], let first = entries.first else { return nil }
            return CodexActivityBlock(id: key, kind: entries.last?.blockKind ?? first.blockKind, entries: entries)
        }
    }
}

@MainActor
private final class ComposerNSTextView: NSTextView {
    override func becomeFirstResponder() -> Bool {
        let didBecome = super.becomeFirstResponder()
        if didBecome {
            InAppTextInsertionManager.shared.register(self)
        }
        return didBecome
    }

    override func resignFirstResponder() -> Bool {
        InAppTextInsertionManager.shared.unregister(self)
        return super.resignFirstResponder()
    }
}

@MainActor
private struct CodexSessionView: View {
    @ObservedObject var model: CodexSessionViewModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            VSplitView {
                activityPane
                resultPane
            }

            Divider()
            composerPane
        }
        .frame(minWidth: 860, minHeight: 680)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.windowTitle)
                        .font(.headline)

                    HStack(spacing: 10) {
                        Text(model.status)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if let threadID = model.threadID {
                            Text(threadID)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }

                Spacer(minLength: 0)

                HStack(spacing: 8) {
                    compactModelPicker
                    compactThinkingPicker
                    compactSpeedPicker

                    if model.isBusy {
                        Button("Stop") {
                            model.stopCurrentTurn()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    private var compactModelPicker: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Model")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Picker("Model", selection: $model.modelOverride) {
                ForEach(CodexModelCatalog.options(currentModel: model.modelOverride)) { option in
                    Text(option.title).tag(option.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .disabled(model.isBusy)
            .frame(width: 170, alignment: .leading)
        }
    }

    private var compactThinkingPicker: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Think")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Picker("Think", selection: $model.reasoningEffort) {
                ForEach(CodexReasoningEffort.allCases) { effort in
                    Text(effort.title).tag(effort)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .disabled(model.isBusy)
            .frame(width: 104, alignment: .leading)
        }
    }

    private var compactSpeedPicker: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Speed")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Picker("Speed", selection: $model.serviceTier) {
                ForEach(CodexServiceTier.allCases) { tier in
                    Text(tier.title).tag(tier)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .disabled(model.isBusy)
            .frame(width: 104, alignment: .leading)
        }
    }

    private var activityPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                    Text("Activity")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                if model.hiddenActivityCount > 0 {
                    Text("Showing latest \(model.visibleBlocks.count) blocks. Older \(model.hiddenActivityCount) raw events hidden to keep this window responsive.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            Divider()
                .padding(.top, 10)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(model.visibleBlocks) { block in
                            CodexActivityBlockView(block: block)
                                .id(block.id)
                        }
                    }
                    .padding(16)
                }
                .onChange(of: model.visibleBlocks.count) {
                    guard let lastID = model.visibleBlocks.last?.id else { return }
                    withAnimation(.easeOut(duration: 0.18)) {
                        proxy.scrollTo(lastID, anchor: .bottom)
                    }
                }
            }
        }
        .frame(minHeight: 220)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var resultPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Text("Latest Response")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                Button("IN") {
                    model.openReader()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(model.latestResponse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Open this response in a clean reader window")
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            Divider()
                .padding(.top, 10)

            if model.latestResponse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                VStack(spacing: 12) {
                    if model.isBusy {
                        ProgressView()
                            .controlSize(.regular)
                    }

                    Text(model.isBusy ? "Waiting for Codex..." : "No rendered response yet")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    let referencedFiles = ActivityFileReferenceParser.paths(in: model.latestResponse)

                    if !referencedFiles.isEmpty {
                        ResponseFileActionsView(paths: referencedFiles)
                            .padding(.horizontal, 16)
                            .padding(.top, 12)
                        Divider()
                            .padding(.top, 10)
                    }

                    RenderedResponseContainer(document: ReaderDocument(kind: .response(model.latestResponse)))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    private var composerPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Continue Chat")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ComposerTextView(text: $model.composerText)
                .frame(minHeight: 84, maxHeight: 140)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                )

            HStack {
                Text(model.isBusy ? "Type here to steer the current Codex turn." : "This window resumes the same Codex session.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Spacer()

                Button(model.isBusy ? "Steer" : "Send") {
                    model.sendComposerText()
                }
                .disabled(model.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.return, modifiers: [.command])
            }
        }
        .padding(16)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

@MainActor
private struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false

        let textView = ComposerNSTextView()
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.textContainerInset = NSSize(width: 8, height: 10)
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.string = text
        textView.delegate = context.coordinator

        context.coordinator.textView = textView
        scrollView.documentView = textView
        DispatchQueue.main.async {
            textView.window?.makeFirstResponder(textView)
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        weak var textView: NSTextView?

        init(text: Binding<String>) {
            _text = text
        }

        func textDidChange(_ notification: Notification) {
            text = textView?.string ?? ""
        }
    }
}

@MainActor
private struct CodexReaderWindowView: View {
    @ObservedObject var model: CodexReaderViewModel

    var body: some View {
        VStack(spacing: 0) {
            if let filePath = model.document.filePath {
                HStack(spacing: 8) {
                    Spacer()

                    Button("Open In Finder") {
                        FileLinkOpener.revealInFinder(filePath)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 8)

                Divider()
            }

            RenderedResponseContainer(document: model.document, standalone: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 860, minHeight: 680)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

@MainActor
private struct ExpandableActivityText: View {
    let text: String
    let font: Font
    let lineLimit: Int?

    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text)
                .font(font)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(expanded ? nil : lineLimit)

            if shouldOfferExpansion {
                Button(expanded ? "Show less" : "Show more") {
                    expanded.toggle()
                }
                .buttonStyle(.plain)
                .font(.caption2)
            }
        }
    }

    private var shouldOfferExpansion: Bool {
        text.count > 480 || text.contains("\n\n") || text.split(separator: "\n").count > 12
    }
}

@MainActor
private struct CodexActivityBlockView: View {
    let block: CodexActivityBlock

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(color)

                Text(block.updatedAt.formatted(date: .omitted, time: .standard))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }

            if let command = block.command, !command.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Command")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Text(command)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.black.opacity(0.06))
                        )
                        .contextMenu {
                            Button("Copy Command") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(command, forType: .string)
                            }
                        }
                }
            }

            if let detail = block.summary, !detail.isEmpty {
                ExpandableActivityText(
                    text: detail,
                    font: detailFont,
                    lineLimit: block.kind == .final ? 8 : 12
                )
            }

            if !block.referencedFilePaths.isEmpty {
                ResponseFileActionsView(paths: block.referencedFilePaths)
            }

            if !block.relatedFiles.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(block.relatedFiles.count == 1 ? "File" : "Files")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    ForEach(block.relatedFiles) { file in
                        CodexActivityFileCard(file: file)
                    }
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
        )
    }

    private var title: String {
        switch block.kind {
        case .command:
            if block.latestEntry.title.contains("Completed") {
                return "Command Completed"
            }
            if block.latestEntry.title.contains("Started") {
                return "Command Running"
            }
            return "Command"
        case .tool:
            return block.latestEntry.title
        case .patch:
            return "Patch Applied"
        case .reasoning:
            return block.latestEntry.title
        case .final:
            return "Final Response"
        case .system:
            return block.latestEntry.title
        }
    }

    private var color: Color {
        switch block.kind {
        case .system:
            return .secondary
        case .reasoning:
            return .primary
        case .command:
            return .orange
        case .tool:
            return .teal
        case .patch:
            return .green
        case .final:
            return .blue
        }
    }

    private var detailFont: Font {
        switch block.latestEntry.detailStyle {
        case .body:
            return block.kind == .final ? .body : .caption
        case .monospaced:
            return .caption.monospaced()
        }
    }
}

@MainActor
private struct ResponseFileActionsView: View {
    let paths: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(paths.count == 1 ? "Detected file" : "Detected files")
                .font(.caption2)
                .foregroundStyle(.secondary)

            ForEach(paths, id: \.self) { path in
                ResponseFileActionRow(path: path)
            }
        }
    }
}

@MainActor
private struct ResponseFileActionRow: View {
    let path: String

    private var isRenderableDocument: Bool {
        ReaderRenderableFileType(path: path) != nil
    }

    var body: some View {
        HStack(spacing: 8) {
            Button {
                FileLinkOpener.openPath(path, line: nil)
            } label: {
                Text(URL(fileURLWithPath: path).lastPathComponent)
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.link)

            Spacer(minLength: 0)

            if isRenderableDocument {
                Button("Open Rendered") {
                    CodexReaderWindowManager.shared.openFileReader(path: path)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Button(isRenderableDocument ? "Open Raw" : "Open") {
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button("Finder") {
                FileLinkOpener.revealInFinder(path)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .contextMenu {
            if isRenderableDocument {
                Button("Open Rendered") {
                    CodexReaderWindowManager.shared.openFileReader(path: path)
                }

                Button("Open Raw") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: path))
                }
            } else {
                Button("Open") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: path))
                }
            }

            Button("Reveal in Finder") {
                FileLinkOpener.revealInFinder(path)
            }

            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(path, forType: .string)
            }
        }
    }
}

@MainActor
private struct CodexActivityFileCard: View {
    let file: CodexActivityFile

    private var isRenderableDocument: Bool {
        ReaderRenderableFileType(path: file.path) != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                FileLinkOpener.openPath(file.path, line: nil)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "doc.text")
                        .foregroundStyle(.blue)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(URL(fileURLWithPath: file.path).lastPathComponent)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        Text(file.kindLabel.map { "\($0) · \(file.path)" } ?? file.path)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(.plain)
            .contextMenu {
                if isRenderableDocument {
                    Button("Open Rendered") {
                        CodexReaderWindowManager.shared.openFileReader(path: file.path)
                    }

                    Button("Open Raw") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: file.path))
                    }
                } else {
                    Button("Open") {
                        FileLinkOpener.openPath(file.path, line: nil)
                    }
                }

                Button("Reveal in Finder") {
                    FileLinkOpener.revealInFinder(file.path)
                }

                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(file.path, forType: .string)
                }
            }

            if let diff = file.diff?.trimmingCharacters(in: .whitespacesAndNewlines), !diff.isEmpty {
                DisclosureGroup("Show diff") {
                    Text(diff)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                }
                .font(.caption)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.45))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
        )
    }
}

@MainActor
private struct RenderedResponseContainer: View {
    let document: ReaderDocument
    var standalone = false

    var body: some View {
        switch RenderedDocument.from(document: document) {
        case let .web(source):
            WebDocumentView(source: source, standalone: standalone)
        case let .richText(attributedString):
            RichTextContentView(attributedString: attributedString, standalone: standalone)
        }
    }
}

private enum WebDocumentSource: Equatable {
    case htmlString(String, baseURL: URL?, allowsJavaScript: Bool)
    case file(URL, allowsJavaScript: Bool)
}

private enum RenderedDocument {
    case web(WebDocumentSource)
    case richText(NSAttributedString)

    static func from(document: ReaderDocument) -> RenderedDocument {
        let body = document.body
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)

        if looksLikeHTML(trimmed) {
            if let filePath = document.filePath, ReaderRenderableFileType(path: filePath) == .html {
                return .web(.file(URL(fileURLWithPath: filePath), allowsJavaScript: true))
            }

            return .web(
                .htmlString(
                    HTMLDocumentRenderer.renderRawHTML(body),
                    baseURL: document.baseURL,
                    allowsJavaScript: true
                )
            )
        }

        return .richText(AttributedTextRenderer.render(response: body))
    }

    private static func looksLikeHTML(_ text: String) -> Bool {
        let lowercase = text.lowercased()
        return lowercase.hasPrefix("<!doctype html") ||
            lowercase.hasPrefix("<html") ||
            lowercase.contains("<body") ||
            lowercase.contains("<main") ||
            lowercase.contains("<div")
    }
}

private enum AttributedTextRenderer {
    static func render(response: String) -> NSAttributedString {
        let preprocessed = MarkdownLinkRewriter.rewrite(text: response)

        if let attributed = try? AttributedString(
            markdown: preprocessed,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .full,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
        ) {
            let mutable = NSMutableAttributedString(attributedString: NSAttributedString(attributed))
            style(mutable)
            FileLinkifier.linkifyBarePaths(in: mutable)
            return mutable
        }

        let mutable = NSMutableAttributedString(
            string: response,
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
                .foregroundColor: NSColor.labelColor,
            ]
        )
        style(mutable)
        FileLinkifier.linkifyBarePaths(in: mutable)
        return mutable
    }

    private static func style(_ attributedString: NSMutableAttributedString) {
        let fullRange = NSRange(location: 0, length: attributedString.length)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 4
        paragraphStyle.paragraphSpacing = 9

        attributedString.addAttributes(
            [
                .paragraphStyle: paragraphStyle,
                .foregroundColor: NSColor.labelColor,
            ],
            range: fullRange
        )
    }
}

private enum HTMLDocumentRenderer {
    static func renderRawHTML(_ response: String) -> String {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.range(of: #"<html[\s>]|<!doctype html"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return response
        }

        return """
        <!doctype html>
        <html>
        <head>
        \(themeHead)
        </head>
        <body class="codex-user-html">
        \(response)
        </body>
        </html>
        """
    }

    private static func injectPresentationTheme(into html: String) -> String {
        if html.range(of: #"</head>"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return html.replacingOccurrences(
                of: "</head>",
                with: "\(themeHead)</head>",
                options: [.regularExpression, .caseInsensitive]
            )
        }

        if html.range(of: #"<html[\s>]"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return html.replacingOccurrences(
                of: #"<html([^>]*)>"#,
                with: "<html$1><head>\(themeHead)</head>",
                options: [.regularExpression, .caseInsensitive]
            )
        }

        return """
        <!doctype html>
        <html>
        <head>
        \(themeHead)
        </head>
        <body>
        \(html)
        </body>
        </html>
        """
    }

    private static func fallbackDocument(for response: String) -> String {
        """
        <!doctype html>
        <html>
        <head>
        \(themeHead)
        </head>
        <body>
        <pre>\(escapeHTML(response))</pre>
        </body>
        </html>
        """
    }

    private static func escapeHTML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static let themeHead = """
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <style>
    :root {
      color-scheme: light;
      --page: #f4efe7;
      --page-alt: #fbf8f2;
      --ink: #18212b;
      --muted: #5e6a74;
      --line: rgba(24, 33, 43, 0.12);
      --link: #005bd3;
      --code-bg: #16202a;
      --code-ink: #f5f7fb;
      --quote: #a4642f;
      --shadow: 0 24px 60px rgba(17, 24, 32, 0.12);
    }

    * { box-sizing: border-box; }

    html, body {
      margin: 0;
      min-height: 100%;
      overflow-y: auto;
      overflow-x: hidden;
      background:
        radial-gradient(circle at top left, rgba(193, 140, 71, 0.12), transparent 28%),
        linear-gradient(180deg, var(--page) 0%, var(--page-alt) 100%);
      color: var(--ink);
      font-family: "Iowan Old Style", "Palatino Linotype", "Book Antiqua", Palatino, Georgia, serif;
      line-height: 1.65;
    }

    body {
      padding: 40px 28px 56px;
    }

    body > * {
      max-width: 920px;
      margin-left: auto;
      margin-right: auto;
    }

    h1, h2, h3, h4, h5, h6 {
      color: #101722;
      line-height: 1.15;
      margin-top: 1.4em;
      margin-bottom: 0.55em;
      font-family: "Avenir Next", "Helvetica Neue", Helvetica, sans-serif;
      letter-spacing: -0.03em;
    }

    h1 { font-size: 2.3rem; }
    h2 { font-size: 1.7rem; }
    h3 { font-size: 1.3rem; }

    p, ul, ol, pre, blockquote, table {
      margin-top: 0;
      margin-bottom: 1.05em;
    }

    ul, ol {
      padding-left: 1.4em;
    }

    li + li {
      margin-top: 0.22em;
    }

    a {
      color: var(--link);
      text-decoration: none;
      border-bottom: 1px solid rgba(0, 91, 211, 0.25);
    }

    a:hover {
      border-bottom-color: rgba(0, 91, 211, 0.7);
    }

    pre, code {
      font-family: "SF Mono", "JetBrains Mono", Menlo, monospace;
    }

    pre {
      overflow-x: auto;
      padding: 18px 20px;
      border-radius: 18px;
      background: var(--code-bg);
      color: var(--code-ink);
      box-shadow: var(--shadow);
      white-space: pre-wrap;
    }

    code {
      font-size: 0.92em;
      background: rgba(17, 24, 32, 0.08);
      padding: 0.12em 0.35em;
      border-radius: 0.4em;
    }

    pre code {
      background: transparent;
      padding: 0;
      color: inherit;
    }

    blockquote {
      border-left: 4px solid rgba(164, 100, 47, 0.35);
      margin-left: 0;
      padding: 0.2em 0 0.2em 1em;
      color: var(--muted);
      font-style: italic;
    }

    table {
      width: 100%;
      border-collapse: collapse;
      background: rgba(255, 255, 255, 0.6);
      border-radius: 14px;
      overflow: hidden;
      box-shadow: 0 12px 30px rgba(17, 24, 32, 0.06);
    }

    th, td {
      padding: 12px 14px;
      border-bottom: 1px solid var(--line);
      text-align: left;
      vertical-align: top;
    }

    th {
      font-family: "Avenir Next", "Helvetica Neue", Helvetica, sans-serif;
      font-size: 0.82rem;
      letter-spacing: 0.02em;
      text-transform: uppercase;
      color: var(--muted);
      background: rgba(24, 33, 43, 0.04);
    }

    hr {
      border: 0;
      height: 1px;
      background: var(--line);
      margin: 2.2em auto;
    }

    img {
      max-width: 100%;
      border-radius: 16px;
      display: block;
      box-shadow: var(--shadow);
    }

    .codex-user-html {
      padding-top: 28px;
    }
    </style>
    """
}

private enum MarkdownLinkRewriter {
    private static let markdownLinkRegex = try! NSRegularExpression(pattern: #"\]\((<)?(/[^)\s>]+)(>)?\)"#)

    static func rewrite(text: String) -> String {
        let source = text as NSString
        let range = NSRange(location: 0, length: source.length)
        let mutable = NSMutableString(string: text)
        let matches = markdownLinkRegex.matches(in: text, range: range).reversed()

        for match in matches {
            guard match.numberOfRanges >= 3 else { continue }
            let rawTarget = source.substring(with: match.range(at: 2))
            let customURL = FileLinkOpener.makeCustomURL(fromToken: rawTarget)
            mutable.replaceCharacters(in: match.range, with: "](\(customURL.absoluteString))")
        }

        return mutable as String
    }
}

@MainActor
private struct RichTextContentView: NSViewRepresentable {
    let attributedString: NSAttributedString
    var standalone = false

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = standalone ? NSSize(width: 28, height: 28) : NSSize(width: 18, height: 18)
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.delegate = context.coordinator
        textView.linkTextAttributes = [
            .foregroundColor: NSColor.systemBlue,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]

        textView.textStorage?.setAttributedString(attributedString)
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        textView.textStorage?.setAttributedString(attributedString)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = link as? URL else { return false }
            FileLinkOpener.open(url)
            return true
        }
    }
}

private enum FileLinkifier {
    private static let barePathRegex = try! NSRegularExpression(pattern: #"/Users/[^\s\])>]+(?::\d+)?"#)

    static func linkifyBarePaths(in attributedString: NSMutableAttributedString) {
        let fullText = attributedString.string
        let range = NSRange(fullText.startIndex..., in: fullText)

        barePathRegex.enumerateMatches(in: fullText, range: range) { match, _, _ in
            guard let match else { return }
            let token = (fullText as NSString).substring(with: match.range)
            let customURL = FileLinkOpener.makeCustomURL(fromToken: token)
            attributedString.addAttribute(.link, value: customURL, range: match.range)
        }
    }
}

private enum ActivityFileReferenceParser {
    private static let markdownLinkRegex = try! NSRegularExpression(pattern: #"\[[^\]]+\]\((<)?(/[^)\s>]+(?:\:\d+)?)(>)?\)"#)
    private static let barePathRegex = try! NSRegularExpression(pattern: #"/Users/[^\s\])>]+(?:\:\d+)?"#)

    static func paths(in text: String) -> [String] {
        let source = text as NSString
        let fullRange = NSRange(location: 0, length: source.length)
        var ordered: [String] = []
        var seen: Set<String> = []

        markdownLinkRegex.enumerateMatches(in: text, range: fullRange) { match, _, _ in
            guard let match, match.numberOfRanges >= 3 else { return }
            let token = source.substring(with: match.range(at: 2))
            let path = normalizedPath(from: token)
            guard FileManager.default.fileExists(atPath: path), !seen.contains(path) else { return }
            ordered.append(path)
            seen.insert(path)
        }

        barePathRegex.enumerateMatches(in: text, range: fullRange) { match, _, _ in
            guard let match else { return }
            let token = source.substring(with: match.range)
            let path = normalizedPath(from: token)
            guard FileManager.default.fileExists(atPath: path), !seen.contains(path) else { return }
            ordered.append(path)
            seen.insert(path)
        }

        return ordered
    }

    private static func normalizedPath(from token: String) -> String {
        let trimmed = token
            .trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let range = trimmed.range(of: #":\d+$"#, options: .regularExpression) {
            return String(trimmed[..<range.lowerBound])
        }

        return trimmed
    }
}

private enum ReaderRenderableFileType: Equatable {
    case html
    case markdown

    init?(path: String) {
        let fileExtension = URL(fileURLWithPath: path).pathExtension.lowercased()
        switch fileExtension {
        case "html", "htm":
            self = .html
        case "md", "markdown":
            self = .markdown
        default:
            return nil
        }
    }

    init?(url: URL) {
        self.init(path: url.path)
    }
}

private enum FileLinkOpener {
    private static let scheme = "miwhisper-open"

    static func makeCustomURL(fromToken token: String) -> URL {
        let parsed = parseToken(token)
        var components = URLComponents()
        components.scheme = scheme
        components.host = "file"
        components.queryItems = [
            URLQueryItem(name: "path", value: parsed.path),
            URLQueryItem(name: "line", value: parsed.line.map(String.init)),
        ].compactMap { $0.value == nil ? nil : $0 }

        return components.url!
    }

    static func open(_ url: URL) {
        guard url.scheme == scheme else {
            NSWorkspace.shared.open(url)
            return
        }

        guard
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let path = components.queryItems?.first(where: { $0.name == "path" })?.value
        else {
            return
        }

        let line = components.queryItems?
            .first(where: { $0.name == "line" })?
            .value
            .flatMap(Int.init)

        openPath(path, line: line)
    }

    static func openPath(_ path: String, line: Int?) {
        if line == nil, ReaderRenderableFileType(path: path) != nil, FileManager.default.fileExists(atPath: path) {
            Task { @MainActor in
                CodexReaderWindowManager.shared.openFileReader(path: path)
            }
            return
        }

        if let line, FileManager.default.fileExists(atPath: path) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xed")
            process.arguments = ["-l", String(line), path]
            try? process.run()
            return
        }

        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    static func revealInFinder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    private static func parseToken(_ token: String) -> (path: String, line: Int?) {
        let trimmed = token
            .trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let range = trimmed.range(of: #":\d+$"#, options: .regularExpression) {
            let path = String(trimmed[..<range.lowerBound])
            let lineString = String(trimmed[range]).dropFirst()
            return (path, Int(lineString))
        }

        return (trimmed, nil)
    }
}

@MainActor
private struct WebDocumentView: NSViewRepresentable {
    let source: WebDocumentSource
    var standalone = false

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let preferences = WKWebpagePreferences()
        preferences.allowsContentJavaScript = source.allowsJavaScript
        configuration.defaultWebpagePreferences = preferences

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsBackForwardNavigationGestures = standalone
        context.coordinator.lastSource = source
        load(source, into: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.lastSource != source else { return }
        context.coordinator.lastSource = source
        load(source, into: webView)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.lastSource = nil
        webView.stopLoading()
        webView.navigationDelegate = nil
    }

    private func load(_ source: WebDocumentSource, into webView: WKWebView) {
        switch source {
        case let .htmlString(html, baseURL, _):
            webView.loadHTMLString(html, baseURL: baseURL)
        case let .file(fileURL, _):
            webView.loadFileURL(fileURL, allowingReadAccessTo: fileURL.deletingLastPathComponent())
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var lastSource: WebDocumentSource?

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            if let url = navigationAction.request.url, navigationAction.navigationType == .linkActivated {
                FileLinkOpener.open(url)
                decisionHandler(.cancel)
                return
            }

            decisionHandler(.allow)
        }
    }
}

private extension WebDocumentSource {
    var allowsJavaScript: Bool {
        switch self {
        case let .htmlString(_, _, allowsJavaScript), let .file(_, allowsJavaScript):
            return allowsJavaScript
        }
    }
}
