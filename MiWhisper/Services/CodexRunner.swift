import Foundation

struct CodexRunResult {
    let prompt: String
    let response: String
    let sessionID: String?
    let stderr: String
}

enum CodexActivityKind: String, Codable {
    case system
    case user
    case assistant
    case tool
    case warning
    case error
}

enum CodexActivityDetailStyle: String, Codable {
    case body
    case monospaced
}

enum CodexActivityBlockKind: String, Codable {
    case system
    case reasoning
    case command
    case tool
    case patch
    case final
}

struct CodexActivityFile: Codable, Identifiable, Hashable {
    let id: String
    let path: String
    let kindLabel: String?
    let diff: String?

    init(path: String, kindLabel: String? = nil, diff: String? = nil) {
        self.path = path
        self.kindLabel = kindLabel
        self.diff = diff
        self.id = [path, kindLabel ?? "", diff ?? ""].joined(separator: "::")
    }
}

struct CodexActivityEntry: Codable, Identifiable {
    let id: UUID
    let sourceID: String?
    let groupID: String?
    let kind: CodexActivityKind
    let blockKind: CodexActivityBlockKind
    let title: String
    let detail: String?
    let detailStyle: CodexActivityDetailStyle
    let command: String?
    let relatedFiles: [CodexActivityFile]
    let createdAt: Date

    init(
        id: UUID = UUID(),
        sourceID: String? = nil,
        groupID: String? = nil,
        kind: CodexActivityKind,
        blockKind: CodexActivityBlockKind? = nil,
        title: String,
        detail: String?,
        detailStyle: CodexActivityDetailStyle = .body,
        command: String? = nil,
        relatedFiles: [CodexActivityFile] = [],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.sourceID = sourceID
        self.kind = kind
        self.groupID = groupID
        self.blockKind = blockKind ?? Self.defaultBlockKind(for: kind)
        self.title = title
        self.detail = detail
        self.detailStyle = detailStyle
        self.command = command
        self.relatedFiles = relatedFiles
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case sourceID
        case groupID
        case kind
        case blockKind
        case title
        case detail
        case detailStyle
        case command
        case relatedFiles
        case createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        sourceID = try container.decodeIfPresent(String.self, forKey: .sourceID)
        groupID = try container.decodeIfPresent(String.self, forKey: .groupID)
        kind = try container.decode(CodexActivityKind.self, forKey: .kind)
        blockKind = try container.decodeIfPresent(CodexActivityBlockKind.self, forKey: .blockKind) ?? Self.defaultBlockKind(for: kind)
        title = try container.decode(String.self, forKey: .title)
        detail = try container.decodeIfPresent(String.self, forKey: .detail)
        detailStyle = try container.decodeIfPresent(CodexActivityDetailStyle.self, forKey: .detailStyle) ?? .body
        command = try container.decodeIfPresent(String.self, forKey: .command)
        relatedFiles = try container.decodeIfPresent([CodexActivityFile].self, forKey: .relatedFiles) ?? []
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }

    private static func defaultBlockKind(for kind: CodexActivityKind) -> CodexActivityBlockKind {
        switch kind {
        case .assistant:
            return .reasoning
        case .tool:
            return .tool
        case .system, .user, .warning, .error:
            return .system
        }
    }
}

extension CodexActivityEntry {
    func sanitizedForStorage(
        maxDetailCharacters: Int = 16_000,
        maxFileDiffCharacters: Int = 8_000
    ) -> CodexActivityEntry {
        CodexActivityEntry(
            id: id,
            sourceID: sourceID,
            groupID: groupID,
            kind: kind,
            blockKind: blockKind,
            title: title,
            detail: detail.map { Self.clippedText($0, maxCharacters: maxDetailCharacters) },
            detailStyle: detailStyle,
            command: command.map { Self.clippedText($0, maxCharacters: 4_000) },
            relatedFiles: relatedFiles.map { file in
                CodexActivityFile(
                    path: file.path,
                    kindLabel: file.kindLabel,
                    diff: file.diff.map { Self.clippedText($0, maxCharacters: maxFileDiffCharacters) }
                )
            },
            createdAt: createdAt
        )
    }

    static func clippedText(
        _ text: String,
        maxCharacters: Int,
        headCharacters: Int? = nil,
        tailCharacters: Int? = nil
    ) -> String {
        guard maxCharacters > 0, text.count > maxCharacters else { return text }

        let defaultHead = min(maxCharacters / 3, max(1_200, maxCharacters / 4))
        let resolvedHead = min(headCharacters ?? defaultHead, maxCharacters - 200)
        let resolvedTail = min(tailCharacters ?? (maxCharacters - resolvedHead), maxCharacters - resolvedHead)

        let head = String(text.prefix(resolvedHead))
        let tail = String(text.suffix(resolvedTail))
        let omittedCount = max(0, text.count - head.count - tail.count)

        return """
        \(head)

        … [\(omittedCount) characters omitted] …

        \(tail)
        """
    }
}

enum CodexRunnerError: LocalizedError {
    case missingExecutable(String)
    case emptyPrompt
    case emptyResponse
    case processBusy
    case noActiveTurn
    case missingThread
    case processFailed(status: Int32, details: String)

    var errorDescription: String? {
        switch self {
        case let .missingExecutable(path):
            return "Codex CLI was not found at \(path)"
        case .emptyPrompt:
            return "The Codex prompt was empty"
        case .emptyResponse:
            return "Codex finished without returning a last message"
        case .processBusy:
            return "Codex is already running in this session"
        case .noActiveTurn:
            return "There is no active Codex turn to steer"
        case .missingThread:
            return "This Codex session does not have a live thread yet"
        case let .processFailed(status, details):
            if details.isEmpty {
                return "Codex CLI failed with exit code \(status)"
            }
            return "Codex CLI failed with exit code \(status): \(details)"
        }
    }
}

enum CodexTurnCommand {
    case start(prompt: String, modelOverride: String?, reasoningEffort: CodexReasoningEffort, serviceTier: CodexServiceTier)
    case resume(sessionID: String, prompt: String, modelOverride: String?, reasoningEffort: CodexReasoningEffort, serviceTier: CodexServiceTier)

    var prompt: String {
        switch self {
        case let .start(prompt, _, _, _), let .resume(_, prompt, _, _, _):
            return prompt
        }
    }

    var sessionID: String? {
        switch self {
        case .start:
            return nil
        case let .resume(sessionID, _, _, _, _):
            return sessionID
        }
    }

    var modelOverride: String? {
        switch self {
        case let .start(_, modelOverride, _, _), let .resume(_, _, modelOverride, _, _):
            guard let modelOverride else { return nil }
            let normalized = modelOverride.trimmingCharacters(in: .whitespacesAndNewlines)
            return normalized.isEmpty ? nil : normalized
        }
    }

    var reasoningEffort: CodexReasoningEffort {
        switch self {
        case let .start(_, _, reasoningEffort, _), let .resume(_, _, _, reasoningEffort, _):
            return reasoningEffort
        }
    }

    var serviceTier: CodexServiceTier {
        switch self {
        case let .start(_, _, _, serviceTier), let .resume(_, _, _, _, serviceTier):
            return serviceTier
        }
    }
}

@MainActor
final class CodexRunner {
    var onActivity: ((CodexActivityEntry) -> Void)?
    var onStateChange: ((Bool) -> Void)?
    var onThreadID: ((String) -> Void)?
    var onTurnCompleted: ((CodexRunResult) -> Void)?
    var onTurnFailed: ((String) -> Void)?
    var onTurnInterrupted: ((String) -> Void)?

    private let executablePath: String
    private let workingDirectory: String

    private var serverProcess: Process?
    private var webSocket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var responseHandlers: [Int: (Result<Any?, Error>) -> Void] = [:]

    private var nextRequestID = 1
    private var initialized = false
    private var threadLoaded = false
    private var isRunningTurn = false
    private var isInterruptRequested = false
    private var isShuttingDown = false

    private var currentPrompt = ""
    private var currentThreadID: String?
    private var activeTurnID: String?
    private var lastAssistantMessage = ""
    private var stderrBuffer = ""
    private var pendingSteerPrompts: [String] = []
    private var streamedAgentMessagePhases: [String: String] = [:]
    private var streamedAgentMessageBuffers: [String: String] = [:]
    private var commandOutputBuffers: [String: String] = [:]
    private var reasoningSummaryBuffers: [String: String] = [:]
    private var planBuffers: [String: String] = [:]

    init(executablePath: String, workingDirectory: String, initialThreadID: String? = nil) {
        self.executablePath = executablePath
        self.workingDirectory = workingDirectory
        self.currentThreadID = initialThreadID
    }

    deinit {
        receiveTask?.cancel()
        webSocket?.cancel(with: .goingAway, reason: nil)
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        serverProcess?.terminate()
    }

    var isRunning: Bool {
        isRunningTurn
    }

    func run(command: CodexTurnCommand) throws {
        let normalizedPrompt = command.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPrompt.isEmpty else {
            throw CodexRunnerError.emptyPrompt
        }

        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            throw CodexRunnerError.missingExecutable(executablePath)
        }

        guard !isRunningTurn else {
            throw CodexRunnerError.processBusy
        }

        currentPrompt = normalizedPrompt
        lastAssistantMessage = ""
        stderrBuffer = ""
        isInterruptRequested = false
        pendingSteerPrompts = []
        isRunningTurn = true

        emitActivity(
            CodexActivityEntry(
                kind: .user,
                title: "Prompt",
                detail: normalizedPrompt
            )
        )
        emitActivity(
            CodexActivityEntry(
                kind: .system,
                title: "Codex Turn Started",
                detail: commandDescription(for: command)
            )
        )
        emitStateChange(true)

        Task { [weak self] in
            await self?.performTurn(command: command)
        }
    }

    func steer(prompt: String) throws {
        let normalizedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPrompt.isEmpty else {
            throw CodexRunnerError.emptyPrompt
        }

        guard isRunningTurn else {
            throw CodexRunnerError.noActiveTurn
        }

        emitActivity(
            CodexActivityEntry(
                kind: .user,
                title: "Steer",
                detail: normalizedPrompt
            )
        )
        emitActivity(
            CodexActivityEntry(
                kind: .system,
                title: "Turn Steer Requested",
                detail: "Sending live guidance into the current Codex turn."
            )
        )

        if activeTurnID == nil {
            pendingSteerPrompts.append(normalizedPrompt)
            return
        }

        Task { [weak self] in
            await self?.performSteer(prompt: normalizedPrompt)
        }
    }

    func cancel() {
        guard isRunningTurn || serverProcess != nil else { return }
        isInterruptRequested = true

        emitActivity(
            CodexActivityEntry(
                kind: .warning,
                title: "Turn Interrupt Requested",
                detail: "Stopping the current Codex turn."
            )
        )

        Task { [weak self] in
            await self?.performInterrupt()
        }
    }

    private func performTurn(command: CodexTurnCommand) async {
        do {
            try await ensureSessionReady(for: command)

            let response = try await sendRequest(
                method: "turn/start",
                params: turnStartParams(for: command)
            )

            if let turnID = extractTurnID(from: response) {
                activeTurnID = turnID
            }

            if isInterruptRequested {
                await performInterrupt()
                return
            }

            await flushPendingSteersIfNeeded()
        } catch {
            isRunningTurn = false
            emitStateChange(false)
            emitTurnFailed(error.localizedDescription)
        }
    }

    private func performSteer(prompt: String) async {
        guard let threadID = currentThreadID else {
            emitActivity(
                CodexActivityEntry(
                    kind: .error,
                    title: "Steer Failed",
                    detail: CodexRunnerError.missingThread.localizedDescription
                )
            )
            return
        }

        guard let expectedTurnID = activeTurnID else {
            pendingSteerPrompts.append(prompt)
            return
        }

        do {
            let response = try await sendRequest(
                method: "turn/steer",
                params: [
                    "threadId": threadID,
                    "expectedTurnId": expectedTurnID,
                    "input": [
                        ["type": "text", "text": prompt]
                    ]
                ]
            )

            if let turnID = (response as? [String: Any])?["turnId"] as? String {
                activeTurnID = turnID
            }
        } catch {
            emitActivity(
                CodexActivityEntry(
                    kind: .error,
                    title: "Steer Failed",
                    detail: error.localizedDescription
                )
            )
        }
    }

    private func performInterrupt() async {
        guard isRunningTurn else {
            return
        }

        guard let threadID = currentThreadID, let turnID = activeTurnID else {
            serverProcess?.terminate()
            return
        }

        do {
            _ = try await sendRequest(
                method: "turn/interrupt",
                params: [
                    "threadId": threadID,
                    "turnId": turnID
                ]
            )
        } catch {
            emitActivity(
                CodexActivityEntry(
                    kind: .warning,
                    title: "Interrupt Fallback",
                    detail: "App-server interrupt failed, terminating the local Codex session process."
                )
            )
            serverProcess?.terminate()
        }
    }

    private func ensureSessionReady(for command: CodexTurnCommand) async throws {
        if !initialized || webSocket == nil || serverProcess == nil {
            try await launchServer()
        }

        switch command {
        case .start:
            guard !threadLoaded else { return }
            let response = try await sendRequest(
                method: "thread/start",
                params: threadStartParams(for: command)
            )
            applyThreadResponse(response)

        case let .resume(sessionID, _, _, _, _):
            if threadLoaded, currentThreadID == sessionID {
                return
            }

            let response = try await sendRequest(
                method: "thread/resume",
                params: threadResumeParams(threadID: sessionID, command: command)
            )
            applyThreadResponse(response)
        }
    }

    private func launchServer() async throws {
        try shutdownConnection(terminateProcess: true)

        var lastError: Error?

        for _ in 0..<4 {
            let port = Int.random(in: 43100...48999)
            let listenURL = "ws://127.0.0.1:\(port)"

            do {
                try startServerProcess(listenURL: listenURL)
                try await connectWebSocket(url: URL(string: listenURL)!)
                return
            } catch {
                lastError = error
                try shutdownConnection(terminateProcess: true)
            }
        }

        throw lastError ?? CodexRunnerError.processFailed(status: -1, details: "Could not launch the Codex app-server")
    }

    private func startServerProcess(listenURL: String) throws {
        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            throw CodexRunnerError.missingExecutable(executablePath)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = [
            "app-server",
            "--listen",
            listenURL
        ]
        process.environment = ProcessInfo.processInfo.environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }

            Task { @MainActor [weak self] in
                self?.consumeProcessLog(data, stream: "stdout")
            }
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }

            Task { @MainActor [weak self] in
                self?.consumeProcessLog(data, stream: "stderr")
            }
        }

        process.terminationHandler = { [weak self] finishedProcess in
            Task { @MainActor [weak self] in
                self?.handleServerTermination(process: finishedProcess)
            }
        }

        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            throw error
        }

        serverProcess = process
        self.stdoutPipe = stdoutPipe
        self.stderrPipe = stderrPipe
    }

    private func connectWebSocket(url: URL) async throws {
        var lastError: Error?

        for _ in 0..<30 {
            let socket = URLSession.shared.webSocketTask(with: url)
            socket.resume()
            webSocket = socket

            do {
                startReceiveLoop()

                _ = try await sendRequest(
                    method: "initialize",
                    params: [
                        "clientInfo": [
                            "name": "miwhisper",
                            "title": "MiWhisper",
                            "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
                        ],
                        "capabilities": [
                            "experimentalApi": true
                        ]
                    ]
                )

                try await sendNotification(method: "initialized")
                initialized = true
                threadLoaded = false
                return
            } catch {
                lastError = error
                receiveTask?.cancel()
                receiveTask = nil
                socket.cancel(with: .goingAway, reason: nil)
                webSocket = nil
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
        }

        throw lastError ?? CodexRunnerError.processFailed(status: -1, details: "Timed out connecting to Codex app-server")
    }

    private func startReceiveLoop() {
        receiveTask?.cancel()
        receiveTask = Task { [weak self] in
            guard let self else { return }
            await self.receiveLoop()
        }
    }

    private func receiveLoop() async {
        while !Task.isCancelled {
            guard let webSocket else { return }

            do {
                let message = try await webSocket.receive()

                switch message {
                case let .string(text):
                    handleIncomingText(text)
                case let .data(data):
                    handleIncomingText(String(decoding: data, as: UTF8.self))
                @unknown default:
                    break
                }
            } catch {
                if Task.isCancelled || isShuttingDown {
                    return
                }

                handleTransportError(error)
                return
            }
        }
    }

    private func sendRequest(method: String, params: Any?) async throws -> Any? {
        let requestID = nextRequestID
        nextRequestID += 1

        let payload = jsonObject(
            id: requestID,
            method: method,
            params: params
        )

        return try await withCheckedThrowingContinuation { continuation in
            responseHandlers[requestID] = { result in
                continuation.resume(with: result)
            }

            Task { @MainActor [weak self] in
                guard let self else { return }

                do {
                    try await self.sendJSON(payload)
                } catch {
                    let handler = self.responseHandlers.removeValue(forKey: requestID)
                    handler?(.failure(error))
                }
            }
        }
    }

    private func sendNotification(method: String, params: Any? = nil) async throws {
        try await sendJSON(jsonObject(id: nil, method: method, params: params))
    }

    private func sendJSON(_ object: [String: Any]) async throws {
        guard let webSocket else {
            throw CodexRunnerError.processFailed(status: -1, details: "Codex app-server socket is not connected")
        }

        let data = try JSONSerialization.data(withJSONObject: object, options: [])
        let text = String(decoding: data, as: UTF8.self)
        try await webSocket.send(.string(text))
    }

    private func handleIncomingText(_ text: String) {
        guard !text.isEmpty else { return }

        guard
            let data = text.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data, options: []),
            let payload = object as? [String: Any]
        else {
            emitActivity(CodexActivityEntry(kind: .system, title: "Codex App-Server", detail: text))
            return
        }

        if let id = payload["id"] as? Int {
            handleResponse(id: id, payload: payload)
            return
        }

        if let method = payload["method"] as? String {
            handleNotification(method: method, params: payload["params"])
        }
    }

    private func handleResponse(id: Int, payload: [String: Any]) {
        guard let handler = responseHandlers.removeValue(forKey: id) else { return }

        if let errorPayload = payload["error"] as? [String: Any] {
            handler(.failure(AppServerError.from(errorPayload)))
            return
        }

        handler(.success(payload["result"]))
    }

    private func handleNotification(method: String, params: Any?) {
        switch method {
        case "thread/started":
            if let params = params as? [String: Any] {
                handleThreadStarted(params)
            }

        case "thread/status/changed":
            if let params = params as? [String: Any] {
                handleThreadStatusChanged(params)
            }

        case "thread/closed":
            threadLoaded = false
            emitActivity(CodexActivityEntry(kind: .warning, title: "Thread Closed", detail: currentThreadID))

        case "turn/started":
            if let params = params as? [String: Any] {
                handleTurnStarted(params)
            }

        case "turn/completed":
            if let params = params as? [String: Any] {
                handleTurnCompleted(params)
            }

        case "item/started":
            if let params = params as? [String: Any] {
                handleItemStarted(params)
            }

        case "item/completed":
            if let params = params as? [String: Any] {
                handleItemCompleted(params)
            }

        case "item/agentMessage/delta":
            if let params = params as? [String: Any] {
                handleAgentMessageDelta(params)
            }

        case "item/reasoning/summaryTextDelta":
            if let params = params as? [String: Any] {
                handleReasoningSummaryDelta(params)
            }

        case "item/plan/delta":
            if let params = params as? [String: Any] {
                handlePlanDelta(params)
            }

        case "item/commandExecution/outputDelta":
            if let params = params as? [String: Any] {
                handleCommandExecutionOutputDelta(params)
            }

        case "error":
            if let params = params as? [String: Any] {
                handleErrorNotification(params)
            }

        default:
            break
        }
    }

    private func handleThreadStarted(_ params: [String: Any]) {
        guard
            let thread = params["thread"] as? [String: Any],
            let threadID = thread["id"] as? String
        else {
            return
        }

        threadLoaded = true
        currentThreadID = threadID
        emitThreadID(threadID)
        emitActivity(CodexActivityEntry(kind: .system, blockKind: .system, title: "Thread Started", detail: threadID))
    }

    private func handleThreadStatusChanged(_ params: [String: Any]) {
        guard let status = params["status"] as? [String: Any] else { return }
        let type = status["type"] as? String ?? "unknown"

        if type == "active", let flags = status["activeFlags"] as? [String], !flags.isEmpty {
            emitActivity(
                CodexActivityEntry(
                    kind: .system,
                    blockKind: .system,
                    title: "Thread Active",
                    detail: flags.joined(separator: ", ")
                )
            )
        } else if type == "systemError" {
            emitActivity(CodexActivityEntry(kind: .error, blockKind: .system, title: "Thread System Error", detail: nil))
        }
    }

    private func handleTurnStarted(_ params: [String: Any]) {
        guard let turn = params["turn"] as? [String: Any] else { return }

        if let turnID = turn["id"] as? String {
            activeTurnID = turnID
        }

        emitActivity(CodexActivityEntry(kind: .system, blockKind: .system, title: "Turn Started", detail: activeTurnID))

        Task { [weak self] in
            await self?.flushPendingSteersIfNeeded()
        }

        if isInterruptRequested {
            Task { [weak self] in
                await self?.performInterrupt()
            }
        }
    }

    private func handleTurnCompleted(_ params: [String: Any]) {
        guard let turn = params["turn"] as? [String: Any] else { return }

        activeTurnID = nil
        isRunningTurn = false
        emitStateChange(false)

        let status = turn["status"] as? String ?? "completed"
        let errorPayload = turn["error"] as? [String: Any]
        let errorMessage = errorPayload?["message"] as? String

        switch status {
        case "completed":
            emitActivity(CodexActivityEntry(kind: .system, blockKind: .system, title: "Turn Completed", detail: nil))

            guard !lastAssistantMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                emitTurnFailed(CodexRunnerError.emptyResponse.localizedDescription)
                resetTurnState()
                return
            }

            emitTurnCompleted(
                CodexRunResult(
                    prompt: currentPrompt,
                    response: lastAssistantMessage.trimmingCharacters(in: .whitespacesAndNewlines),
                    sessionID: currentThreadID,
                    stderr: stderrBuffer
                )
            )

        case "interrupted":
            let interruptionMessage = currentThreadID.map { "Interrupted • \($0)" } ?? "Interrupted"
            emitTurnInterrupted(interruptionMessage)

        case "failed":
            emitTurnFailed(errorMessage ?? "Codex turn failed")

        default:
            emitTurnFailed(errorMessage ?? "Codex turn ended unexpectedly")
        }

        resetTurnState()
    }

    private func handleItemStarted(_ params: [String: Any]) {
        guard let item = params["item"] as? [String: Any] else { return }
        emitActivity(startedEntry(for: item))
    }

    private func handleItemCompleted(_ params: [String: Any]) {
        guard let item = params["item"] as? [String: Any] else { return }

        if let type = item["type"] as? String, type == "agentMessage", let text = item["text"] as? String, !text.isEmpty {
            lastAssistantMessage = text
        }

        emitActivity(completedEntry(for: item))
    }

    private func handleAgentMessageDelta(_ params: [String: Any]) {
        guard
            let itemID = params["itemId"] as? String,
            let delta = params["delta"] as? String
        else {
            return
        }

        let phase = streamedAgentMessagePhases[itemID] ?? "final_answer"
        let existing = streamedAgentMessageBuffers[itemID] ?? ""
        let updated = CodexActivityEntry.clippedText(existing + delta, maxCharacters: 18_000)
        streamedAgentMessageBuffers[itemID] = updated

        if phase == "commentary" {
            emitActivity(
                CodexActivityEntry(
                    sourceID: "agent-commentary-\(itemID)",
                    groupID: "reasoning-commentary-\(itemID)",
                    kind: .assistant,
                    blockKind: .reasoning,
                    title: "Codex Thinking",
                    detail: updated,
                    detailStyle: .body
                )
            )
        } else {
            lastAssistantMessage += delta
        }
    }

    private func handleReasoningSummaryDelta(_ params: [String: Any]) {
        guard
            let itemID = params["itemId"] as? String,
            let delta = params["delta"] as? String
        else {
            return
        }

        let updated = CodexActivityEntry.clippedText((reasoningSummaryBuffers[itemID] ?? "") + delta, maxCharacters: 14_000)
        reasoningSummaryBuffers[itemID] = updated

        emitActivity(
            CodexActivityEntry(
                sourceID: "reasoning-\(itemID)",
                groupID: "reasoning-\(itemID)",
                kind: .assistant,
                blockKind: .reasoning,
                title: "Reasoning Summary",
                detail: updated,
                detailStyle: .body
            )
        )
    }

    private func handlePlanDelta(_ params: [String: Any]) {
        guard
            let itemID = params["itemId"] as? String,
            let delta = params["delta"] as? String
        else {
            return
        }

        let updated = CodexActivityEntry.clippedText((planBuffers[itemID] ?? "") + delta, maxCharacters: 14_000)
        planBuffers[itemID] = updated

        emitActivity(
            CodexActivityEntry(
                sourceID: "plan-\(itemID)",
                groupID: "plan-\(itemID)",
                kind: .assistant,
                blockKind: .reasoning,
                title: "Plan",
                detail: updated,
                detailStyle: .body
            )
        )
    }

    private func handleCommandExecutionOutputDelta(_ params: [String: Any]) {
        guard
            let itemID = params["itemId"] as? String,
            let delta = params["delta"] as? String
        else {
            return
        }

        let updated = CodexActivityEntry.clippedText((commandOutputBuffers[itemID] ?? "") + delta, maxCharacters: 20_000)
        commandOutputBuffers[itemID] = updated

        emitActivity(
            CodexActivityEntry(
                sourceID: "command-output-\(itemID)",
                groupID: "command-\(itemID)",
                kind: .tool,
                blockKind: .command,
                title: "Command Output",
                detail: updated,
                detailStyle: .monospaced
            )
        )
    }

    private func handleErrorNotification(_ params: [String: Any]) {
        let willRetry = params["willRetry"] as? Bool ?? false
        let errorPayload = params["error"] as? [String: Any]
        let message = errorPayload?["message"] as? String ?? "Codex reported an error"

        emitActivity(
            CodexActivityEntry(
                kind: willRetry ? .warning : .error,
                blockKind: .system,
                title: willRetry ? "Codex Warning" : "Codex Error",
                detail: message
            )
        )
    }

    private func handleTransportError(_ error: Error) {
        completePendingResponses(with: .failure(error))

        if isRunningTurn {
            isRunningTurn = false
            emitStateChange(false)
            emitTurnFailed(error.localizedDescription)
            resetTurnState()
        }

        threadLoaded = false
        initialized = false
        webSocket = nil
        receiveTask = nil
    }

    private func handleServerTermination(process: Process) {
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil

        if process === serverProcess {
            serverProcess = nil
        }

        if isShuttingDown {
            return
        }

        if isInterruptRequested, isRunningTurn {
            isRunningTurn = false
            emitStateChange(false)
            let interruptionMessage = currentThreadID.map { "Interrupted • \($0)" } ?? "Interrupted"
            emitTurnInterrupted(interruptionMessage)
            resetTurnState()
            return
        }

        let details = stderrBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        let error = CodexRunnerError.processFailed(status: process.terminationStatus, details: details)
        handleTransportError(error)
    }

    private func consumeProcessLog(_ data: Data, stream: String) {
        let text = String(decoding: data, as: UTF8.self)
        guard !text.isEmpty else { return }

        if stream == "stderr" {
            stderrBuffer += text
        }

        let lines = text.split(whereSeparator: \.isNewline)
        for line in lines {
            let message = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !message.isEmpty else { continue }

            if message.localizedCaseInsensitiveContains("warning") {
            emitActivity(CodexActivityEntry(kind: .warning, blockKind: .system, title: "Codex Log", detail: message))
            } else if message.localizedCaseInsensitiveContains("error") {
                emitActivity(CodexActivityEntry(kind: .error, blockKind: .system, title: "Codex Log", detail: message))
            } else {
                emitActivity(CodexActivityEntry(kind: .system, blockKind: .system, title: "Codex Log", detail: message))
            }
        }
    }

    private func shutdownConnection(terminateProcess: Bool) throws {
        isShuttingDown = true
        receiveTask?.cancel()
        receiveTask = nil
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        completePendingResponses(with: .failure(CancellationError()))

        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        stdoutPipe = nil
        stderrPipe = nil

        if terminateProcess {
            serverProcess?.terminate()
            serverProcess = nil
        }

        initialized = false
        threadLoaded = false
        activeTurnID = nil
        isShuttingDown = false
    }

    private func completePendingResponses(with result: Result<Any?, Error>) {
        let handlers = responseHandlers.values
        responseHandlers.removeAll()
        handlers.forEach { $0(result) }
    }

    private func applyThreadResponse(_ response: Any?) {
        guard
            let response = response as? [String: Any],
            let thread = response["thread"] as? [String: Any],
            let threadID = thread["id"] as? String
        else {
            return
        }

        currentThreadID = threadID
        threadLoaded = true
        emitThreadID(threadID)
    }

    private func extractTurnID(from response: Any?) -> String? {
        guard
            let response = response as? [String: Any],
            let turn = response["turn"] as? [String: Any]
        else {
            return nil
        }

        return turn["id"] as? String
    }

    private func flushPendingSteersIfNeeded() async {
        guard !pendingSteerPrompts.isEmpty else { return }

        let prompts = pendingSteerPrompts
        pendingSteerPrompts.removeAll()

        for prompt in prompts {
            await performSteer(prompt: prompt)
        }
    }

    private func resetTurnState() {
        currentPrompt = ""
        activeTurnID = nil
        lastAssistantMessage = ""
        isInterruptRequested = false
        pendingSteerPrompts = []
        streamedAgentMessagePhases = [:]
        streamedAgentMessageBuffers = [:]
        commandOutputBuffers = [:]
        reasoningSummaryBuffers = [:]
        planBuffers = [:]
    }

    private func commandDescription(for command: CodexTurnCommand) -> String {
        let model = command.modelOverride ?? "config default"
        let reasoning = command.reasoningEffort.title
        let speed = command.serviceTier.title

        switch command {
        case .start:
            return "new session via app-server · model \(model) · think \(reasoning) · speed \(speed) · full access"
        case let .resume(sessionID, _, _, _, _):
            return "resume \(sessionID) via app-server · model \(model) · think \(reasoning) · speed \(speed) · full access"
        }
    }

    private func threadStartParams(for command: CodexTurnCommand) -> [String: Any] {
        var params: [String: Any] = [
            "cwd": workingDirectory,
            "approvalPolicy": "never",
            "sandbox": "danger-full-access",
            "personality": "pragmatic"
        ]

        if let model = command.modelOverride {
            params["model"] = model
        }

        if let serviceTier = command.serviceTier.appServerValue {
            params["serviceTier"] = serviceTier
        }

        return params
    }

    private func threadResumeParams(threadID: String, command: CodexTurnCommand) -> [String: Any] {
        var params: [String: Any] = [
            "threadId": threadID,
            "cwd": workingDirectory,
            "approvalPolicy": "never",
            "sandbox": "danger-full-access",
            "personality": "pragmatic"
        ]

        if let model = command.modelOverride {
            params["model"] = model
        }

        if let serviceTier = command.serviceTier.appServerValue {
            params["serviceTier"] = serviceTier
        }

        return params
    }

    private func turnStartParams(for command: CodexTurnCommand) -> [String: Any] {
        var params: [String: Any] = [
            "threadId": currentThreadID ?? command.sessionID ?? "",
            "input": [
                ["type": "text", "text": command.prompt]
            ],
            "approvalPolicy": "never",
            "sandboxPolicy": ["type": "dangerFullAccess"],
            "personality": "pragmatic"
        ]

        if let model = command.modelOverride {
            params["model"] = model
        }

        if let effort = command.reasoningEffort.cliValue {
            params["effort"] = effort
        }

        if let serviceTier = command.serviceTier.appServerValue {
            params["serviceTier"] = serviceTier
        }

        return params
    }

    private func startedEntry(for item: [String: Any]) -> CodexActivityEntry {
        let type = item["type"] as? String ?? "other"
        let itemID = item["id"] as? String

        switch type {
        case "mcpToolCall":
            let server = item["server"] as? String
            let tool = item["tool"] as? String
            return CodexActivityEntry(
                sourceID: itemID.map { "tool-\($0)" },
                groupID: itemID.map { "tool-\($0)" },
                kind: .tool,
                blockKind: .tool,
                title: "Tool Started",
                detail: [server, tool].compactMap { $0 }.joined(separator: ".")
            )

        case "commandExecution":
            let command = item["command"] as? String
            let relatedFiles = files(fromCommandActions: item["commandActions"] as? [[String: Any]] ?? [])
            return CodexActivityEntry(
                sourceID: itemID.map { "command-\($0)" },
                groupID: itemID.map { "command-\($0)" },
                kind: .tool,
                blockKind: .command,
                title: "Command Started",
                detail: relatedFiles.isEmpty ? "Live output will appear below as Codex runs this command." : "Command started with file-aware actions.",
                detailStyle: .body,
                command: command,
                relatedFiles: relatedFiles
            )

        case "agentMessage":
            let phase = item["phase"] as? String ?? "final_answer"
            if let itemID {
                streamedAgentMessagePhases[itemID] = phase
            }
            return CodexActivityEntry(
                sourceID: itemID.map { "agent-\($0)" },
                groupID: itemID.map {
                    phase == "commentary" ? "reasoning-commentary-\($0)" : "final-\($0)"
                },
                kind: .assistant,
                blockKind: phase == "commentary" ? .reasoning : .final,
                title: phase == "commentary" ? "Codex Thinking" : "Codex",
                detail: item["text"] as? String,
                detailStyle: .body
            )

        case "reasoning":
            return CodexActivityEntry(
                sourceID: itemID.map { "reasoning-\($0)" },
                groupID: itemID.map { "reasoning-\($0)" },
                kind: .assistant,
                blockKind: .reasoning,
                title: "Reasoning",
                detail: nil
            )

        default:
            return CodexActivityEntry(
                sourceID: itemID.map { "item-\($0)" },
                groupID: itemID.map { "item-\($0)" },
                kind: .system,
                blockKind: .system,
                title: "Item Started",
                detail: type
            )
        }
    }

    private func completedEntry(for item: [String: Any]) -> CodexActivityEntry {
        let type = item["type"] as? String ?? "other"
        let itemID = item["id"] as? String

        switch type {
        case "agentMessage":
            let phase = item["phase"] as? String ?? "final_answer"
            return CodexActivityEntry(
                sourceID: itemID.map {
                    phase == "commentary" ? "agent-commentary-\($0)" : "agent-\($0)"
                },
                groupID: itemID.map {
                    phase == "commentary" ? "reasoning-commentary-\($0)" : "final-\($0)"
                },
                kind: .assistant,
                blockKind: phase == "commentary" ? .reasoning : .final,
                title: phase == "commentary" ? "Codex Thinking" : "Codex",
                detail: item["text"] as? String,
                detailStyle: .body
            )

        case "mcpToolCall":
            let server = item["server"] as? String
            let tool = item["tool"] as? String
            let resultPreview = summarizeMcpToolCallResult(item["result"])
            return CodexActivityEntry(
                sourceID: itemID.map { "tool-\($0)" },
                groupID: itemID.map { "tool-\($0)" },
                kind: .tool,
                blockKind: .tool,
                title: "Tool Completed",
                detail: [[server, tool].compactMap { $0 }.joined(separator: "."), resultPreview]
                    .compactMap { $0 }
                    .joined(separator: "\n"),
                detailStyle: .body
            )

        case "commandExecution":
            let command = item["command"] as? String
            let exitCode = item["exitCode"] as? Int
            let aggregatedOutput = (item["aggregatedOutput"] as? String)
                .map { CodexActivityEntry.clippedText($0, maxCharacters: 24_000) }
            let summary = exitCode.map { "Exit code \($0)" } ?? "Completed"
            let detail = [summary, aggregatedOutput].compactMap { value in
                guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
                return trimmed
            }.joined(separator: "\n\n")

            return CodexActivityEntry(
                sourceID: itemID.map { "command-\($0)" },
                groupID: itemID.map { "command-\($0)" },
                kind: .tool,
                blockKind: .command,
                title: "Command Completed",
                detail: detail.isEmpty ? nil : detail,
                detailStyle: .monospaced,
                command: command,
                relatedFiles: files(fromCommandActions: item["commandActions"] as? [[String: Any]] ?? [])
            )

        case "fileChange":
            let changes = item["changes"] as? [[String: Any]] ?? []
            return CodexActivityEntry(
                sourceID: itemID.map { "file-change-\($0)" },
                groupID: itemID.map { "patch-\($0)" },
                kind: .tool,
                blockKind: .patch,
                title: "File Change Applied",
                detail: summarizeFileChanges(changes),
                detailStyle: .monospaced,
                relatedFiles: files(fromFileChanges: changes)
            )

        default:
            return CodexActivityEntry(
                sourceID: itemID.map { "item-\($0)" },
                groupID: itemID.map { "item-\($0)" },
                kind: .system,
                blockKind: .system,
                title: "Item Completed",
                detail: type
            )
        }
    }

    private func files(fromCommandActions actions: [[String: Any]]) -> [CodexActivityFile] {
        actions.compactMap { action in
            guard let type = action["type"] as? String else { return nil }

            switch type {
            case "read":
                guard let path = action["path"] as? String else { return nil }
                return CodexActivityFile(path: path, kindLabel: "read")
            case "listFiles":
                guard let path = action["path"] as? String else { return nil }
                return CodexActivityFile(path: path, kindLabel: "list")
            case "search":
                guard let path = action["path"] as? String else { return nil }
                return CodexActivityFile(path: path, kindLabel: "search")
            default:
                return nil
            }
        }
    }

    private func files(fromFileChanges changes: [[String: Any]]) -> [CodexActivityFile] {
        changes.compactMap { change in
            guard let path = change["path"] as? String else { return nil }
            let kindLabel = summarizePatchChangeKind(change["kind"] as? [String: Any])
            let diff = (change["diff"] as? String)
                .map { CodexActivityEntry.clippedText($0, maxCharacters: 8_000) }
            return CodexActivityFile(path: path, kindLabel: kindLabel, diff: diff)
        }
    }

    private func summarizePatchChangeKind(_ payload: [String: Any]?) -> String? {
        guard let payload, let type = payload["type"] as? String else { return nil }

        switch type {
        case "add":
            return "created"
        case "delete":
            return "deleted"
        case "update":
            if let movePath = payload["move_path"] as? String, !movePath.isEmpty {
                return "moved from \(movePath)"
            }
            return "updated"
        default:
            return type
        }
    }

    private func summarizeFileChanges(_ changes: [[String: Any]]) -> String {
        let lines = changes.compactMap { change -> String? in
            guard let path = change["path"] as? String else { return nil }
            let kindLabel = summarizePatchChangeKind(change["kind"] as? [String: Any]) ?? "changed"
            let diffPreview = (change["diff"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: "\n")
                .prefix(8)
                .joined(separator: "\n")

            if let diffPreview, !diffPreview.isEmpty {
                return "\(kindLabel) \(path)\n\(diffPreview)"
            }

            return "\(kindLabel) \(path)"
        }

        return lines.joined(separator: "\n\n")
    }

    private func summarizeMcpToolCallResult(_ result: Any?) -> String? {
        guard let result = result as? [String: Any] else { return nil }

        if
            let content = result["content"] as? [[String: Any]],
            let text = content.compactMap({ $0["text"] as? String }).first(where: { !$0.isEmpty })
        {
            return text
        }

        return nil
    }

    private func jsonObject(id: Int?, method: String, params: Any?) -> [String: Any] {
        var payload: [String: Any] = ["method": method]

        if let id {
            payload["id"] = id
        }

        if let params {
            payload["params"] = params
        }

        return payload
    }

    private func emitActivity(_ entry: CodexActivityEntry) {
        onActivity?(entry)
    }

    private func emitStateChange(_ running: Bool) {
        onStateChange?(running)
    }

    private func emitThreadID(_ threadID: String) {
        onThreadID?(threadID)
    }

    private func emitTurnCompleted(_ result: CodexRunResult) {
        onTurnCompleted?(result)
    }

    private func emitTurnFailed(_ message: String) {
        onTurnFailed?(message)
    }

    private func emitTurnInterrupted(_ message: String) {
        onTurnInterrupted?(message)
    }
}

private struct AppServerError: LocalizedError {
    let message: String

    var errorDescription: String? { message }

    static func from(_ payload: [String: Any]) -> AppServerError {
        if let message = payload["message"] as? String {
            return AppServerError(message: message)
        }

        if
            let errorPayload = payload["error"] as? [String: Any],
            let message = errorPayload["message"] as? String
        {
            return AppServerError(message: message)
        }

        return AppServerError(message: "Codex app-server returned an unknown error")
    }
}
