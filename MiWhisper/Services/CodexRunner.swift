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

struct CodexTurnAttachment {
    enum Kind: String {
        case localImage
        case image
    }

    let kind: Kind
    let path: String?
    let url: String?
    let name: String?
    let mimeType: String?

    var appServerInputItem: [String: Any]? {
        switch kind {
        case .localImage:
            guard let path, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return ["type": "local_image", "path": path]
        case .image:
            guard let url, !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return ["type": "image", "image_url": url]
        }
    }
}

enum CodexTurnCommand {
    case start(prompt: String, modelOverride: String?, reasoningEffort: CodexReasoningEffort, serviceTier: CodexServiceTier, accessMode: CodexAccessMode, attachments: [CodexTurnAttachment])
    case resume(sessionID: String, prompt: String, modelOverride: String?, reasoningEffort: CodexReasoningEffort, serviceTier: CodexServiceTier, accessMode: CodexAccessMode, attachments: [CodexTurnAttachment])

    var prompt: String {
        switch self {
        case let .start(prompt, _, _, _, _, _), let .resume(_, prompt, _, _, _, _, _):
            return prompt
        }
    }

    var sessionID: String? {
        switch self {
        case .start:
            return nil
        case let .resume(sessionID, _, _, _, _, _, _):
            return sessionID
        }
    }

    var modelOverride: String? {
        switch self {
        case let .start(_, modelOverride, _, _, _, _), let .resume(_, _, modelOverride, _, _, _, _):
            guard let modelOverride else { return nil }
            let normalized = modelOverride.trimmingCharacters(in: .whitespacesAndNewlines)
            return normalized.isEmpty ? nil : normalized
        }
    }

    var reasoningEffort: CodexReasoningEffort {
        switch self {
        case let .start(_, _, reasoningEffort, _, _, _), let .resume(_, _, _, reasoningEffort, _, _, _):
            return reasoningEffort
        }
    }

    var serviceTier: CodexServiceTier {
        switch self {
        case let .start(_, _, _, serviceTier, _, _), let .resume(_, _, _, _, serviceTier, _, _):
            return serviceTier
        }
    }

    var accessMode: CodexAccessMode {
        switch self {
        case let .start(_, _, _, _, accessMode, _), let .resume(_, _, _, _, _, accessMode, _):
            return accessMode
        }
    }

    var attachments: [CodexTurnAttachment] {
        switch self {
        case let .start(_, _, _, _, _, attachments), let .resume(_, _, _, _, _, _, attachments):
            return attachments
        }
    }

    var appServerInputItems: [[String: Any]] {
        var items: [[String: Any]] = [
            ["type": "text", "text": prompt, "text_elements": []]
        ]
        items.append(contentsOf: attachments.compactMap(\.appServerInputItem))
        return items
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
    private var pendingSteers: [(prompt: String, attachments: [CodexTurnAttachment])] = []
    private var pendingServerRequests: [Int: (method: String, params: Any?)] = [:]
    private var streamedAgentMessagePhases: [String: String] = [:]
    private var streamedAgentMessageBuffers: [String: String] = [:]
    private var commandOutputBuffers: [String: String] = [:]
    private var fileChangeOutputBuffers: [String: String] = [:]
    private var reasoningSummaryBuffers: [String: String] = [:]
    private var planBuffers: [String: String] = [:]
    private var pendingCompletionTask: Task<Void, Never>?

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

    func resolveServerRequest(requestID: Int, decision: String) throws {
        guard let pending = pendingServerRequests.removeValue(forKey: requestID) else {
            throw CodexRunnerError.processFailed(status: -1, details: "Approval request \(requestID) is no longer pending.")
        }

        let result: [String: Any]
        switch pending.method {
        case "item/commandExecution/requestApproval":
            guard ["accept", "acceptForSession", "decline", "cancel"].contains(decision) else {
                throw CodexRunnerError.processFailed(status: -1, details: "Unsupported command approval decision \(decision).")
            }
            result = ["decision": decision]

        case "item/fileChange/requestApproval":
            guard ["accept", "acceptForSession", "decline", "cancel"].contains(decision) else {
                throw CodexRunnerError.processFailed(status: -1, details: "Unsupported file-change approval decision \(decision).")
            }
            result = ["decision": decision]

        case "item/permissions/requestApproval":
            guard ["accept", "acceptForSession", "decline", "cancel"].contains(decision) else {
                throw CodexRunnerError.processFailed(status: -1, details: "Unsupported permissions approval decision \(decision).")
            }
            let params = pending.params as? [String: Any] ?? [:]
            let requestedPermissions = params["permissions"] as? [String: Any] ?? [:]
            let grantedPermissions = decision == "accept" || decision == "acceptForSession" ? requestedPermissions : [:]
            result = [
                "permissions": grantedPermissions,
                "scope": decision == "acceptForSession" ? "session" : "turn"
            ]

        default:
            throw CodexRunnerError.processFailed(status: -1, details: "MiWhisper cannot resolve app-server request \(pending.method).")
        }

        Task { @MainActor [weak self] in
            do {
                try await self?.sendJSON(["id": requestID, "result": result])
                self?.emitActivity(
                    CodexActivityEntry(
                        sourceID: "approval-resolved-\(requestID)",
                        groupID: "approval-\(requestID)",
                        kind: decision == "decline" || decision == "cancel" ? .warning : .system,
                        blockKind: .system,
                        title: "Approval \(decision == "accept" || decision == "acceptForSession" ? "Approved" : "Rejected")",
                        detail: pending.method
                    )
                )
                if decision == "cancel" {
                    await self?.performInterrupt()
                }
            } catch {
                self?.pendingServerRequests[requestID] = pending
                self?.emitActivity(
                    CodexActivityEntry(
                        kind: .error,
                        blockKind: .system,
                        title: "Approval Response Failed",
                        detail: error.localizedDescription
                    )
                )
            }
        }
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
        pendingSteers = []
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

    func steer(prompt: String, attachments: [CodexTurnAttachment] = []) throws {
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
                detail: userFacingPromptDetail(prompt: normalizedPrompt, attachments: attachments)
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
            pendingSteers.append((prompt: normalizedPrompt, attachments: attachments))
            return
        }

        Task { [weak self] in
            await self?.performSteer(prompt: normalizedPrompt, attachments: attachments)
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

    private func performSteer(prompt: String, attachments: [CodexTurnAttachment] = []) async {
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
            pendingSteers.append((prompt: prompt, attachments: attachments))
            return
        }

        do {
            let response = try await sendRequest(
                method: "turn/steer",
                params: [
                    "threadId": threadID,
                    "expectedTurnId": expectedTurnID,
                    "input": appServerInputItems(prompt: prompt, attachments: attachments)
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

        case let .resume(sessionID, _, _, _, _, _, _):
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
            socket.maximumMessageSize = 64 * 1024 * 1024
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

        if let method = payload["method"] as? String {
            if let id = payload["id"] as? Int {
                handleServerRequest(id: id, method: method, params: payload["params"])
            } else {
                handleNotification(method: method, params: payload["params"])
            }
            return
        }

        if let id = payload["id"] as? Int {
            handleResponse(id: id, payload: payload)
        }
    }

    private func handleServerRequest(id: Int, method: String, params: Any?) {
        if canResolveServerRequest(method) {
            pendingServerRequests[id] = (method: method, params: params)
            emitActivity(approvalRequestEntry(id: id, method: method, params: params))
            return
        }

        let detail = userFacingServerRequestDetail(method: method, params: params)
        emitActivity(
            CodexActivityEntry(
                kind: .warning,
                blockKind: .system,
                title: "Codex Needs Attention",
                detail: detail
            )
        )

        Task { @MainActor [weak self] in
            do {
                try await self?.sendJSON([
                    "id": id,
                    "error": [
                        "code": -32601,
                        "message": "MiWhisper does not yet support app-server request \(method)."
                    ]
                ])
            } catch {
                self?.emitActivity(
                    CodexActivityEntry(
                        kind: .error,
                        blockKind: .system,
                        title: "Codex Request Failed",
                        detail: error.localizedDescription
                    )
                )
            }
        }
    }

    private func canResolveServerRequest(_ method: String) -> Bool {
        method == "item/commandExecution/requestApproval" ||
            method == "item/fileChange/requestApproval" ||
            method == "item/permissions/requestApproval"
    }

    private func approvalRequestEntry(id: Int, method: String, params: Any?) -> CodexActivityEntry {
        let params = params as? [String: Any] ?? [:]
        let command = params["command"] as? String
        let cwd = params["cwd"] as? String
        let reason = params["reason"] as? String
        let grantRoot = params["grantRoot"] as? String

        let title: String
        let detailParts: [String?]
        let relatedFiles: [CodexActivityFile]

        switch method {
        case "item/commandExecution/requestApproval":
            title = "Codex Approval Requested"
            relatedFiles = files(fromCommandActions: params["commandActions"] as? [[String: Any]] ?? [])
            detailParts = [
                "Request ID: \(id)",
                "Type: command",
                reason.map { "Reason: \($0)" },
                cwd.map { "CWD: \($0)" },
                command.map { "Command:\n\($0)" }
            ]

        case "item/fileChange/requestApproval":
            title = "Codex Approval Requested"
            relatedFiles = grantRoot.map { [CodexActivityFile(path: $0, kindLabel: "write root")] } ?? []
            detailParts = [
                "Request ID: \(id)",
                "Type: file-change",
                reason.map { "Reason: \($0)" },
                grantRoot.map { "Grant root: \($0)" }
            ]

        case "item/permissions/requestApproval":
            title = "Codex Permission Requested"
            let permissions = params["permissions"] as? [String: Any] ?? [:]
            relatedFiles = files(fromPermissions: permissions)
            detailParts = [
                "Request ID: \(id)",
                "Type: permissions",
                reason.map { "Reason: \($0)" },
                cwd.map { "CWD: \($0)" },
                permissionsSummary(from: permissions).map { "Permissions:\n\($0)" }
            ]

        default:
            title = "Codex Needs Attention"
            relatedFiles = []
            detailParts = ["Request ID: \(id)", method]
        }

        return CodexActivityEntry(
            sourceID: "approval-request-\(id)",
            groupID: "approval-\(id)",
            kind: .warning,
            blockKind: .system,
            title: title,
            detail: detailParts.compactMap { $0 }.joined(separator: "\n"),
            detailStyle: .body,
            command: command,
            relatedFiles: relatedFiles
        )
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

        case "item/commandExecution/outputDelta", "command/exec/outputDelta":
            if let params = params as? [String: Any] {
                handleCommandExecutionOutputDelta(params)
            }

        case "item/fileChange/outputDelta":
            if let params = params as? [String: Any] {
                handleFileChangeOutputDelta(params)
            }

        case "item/fileChange/patchUpdated":
            if let params = params as? [String: Any] {
                handleFileChangePatchUpdated(params)
            }

        case "turn/diff/updated":
            if let params = params as? [String: Any] {
                handleTurnDiffUpdated(params)
            }

        case "turn/plan/updated":
            if let params = params as? [String: Any] {
                handleTurnPlanUpdated(params)
            }

        case "thread/tokenUsage/updated":
            if let params = params as? [String: Any] {
                handleThreadTokenUsageUpdated(params)
            }

        case "warning", "guardianWarning", "configWarning", "deprecationNotice":
            if let params = params as? [String: Any] {
                handleWarningNotification(method: method, params)
            }

        case "error":
            if let params = params as? [String: Any] {
                handleErrorNotification(params)
            }

        default:
            break
        }
    }

    private func userFacingServerRequestDetail(method: String, params: Any?) -> String {
        switch method {
        case "item/commandExecution/requestApproval":
            return "Codex requested command approval. If this appears without action buttons, reload the Companion PWA."
        case "item/fileChange/requestApproval":
            return "Codex requested file-change approval. If this appears without action buttons, reload the Companion PWA."
        case "item/permissions/requestApproval":
            return "Codex requested additional permissions. If this appears without action buttons, reload the Companion PWA."
        case "item/tool/requestUserInput":
            return "Codex requested structured user input. Continue from the Mac or steer the turn with the requested answer."
        case "mcpServer/elicitation/request":
            return "An MCP server requested input. MiWhisper does not yet render this request type."
        default:
            if let params,
               let data = try? JSONSerialization.data(withJSONObject: params, options: []),
               let text = String(data: data, encoding: .utf8),
               !text.isEmpty {
                return "\(method)\n\(CodexActivityEntry.clippedText(text, maxCharacters: 2_000))"
            }
            return method
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
            completeFinishedTurnWithGracePeriod()
            return

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

    private func completeFinishedTurnWithGracePeriod() {
        pendingCompletionTask?.cancel()

        let finalize: @MainActor () -> Void = { [weak self] in
            guard let self else { return }
            let resolvedResponse = self.resolvedAssistantMessage()
            guard !resolvedResponse.isEmpty else {
                self.emitTurnFailed(CodexRunnerError.emptyResponse.localizedDescription)
                self.resetTurnState()
                return
            }

            self.emitTurnCompleted(
                CodexRunResult(
                    prompt: self.currentPrompt,
                    response: resolvedResponse,
                    sessionID: self.currentThreadID,
                    stderr: self.stderrBuffer
                )
            )
            self.resetTurnState()
        }

        if !resolvedAssistantMessage().isEmpty {
            finalize()
            return
        }

        pendingCompletionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard let self, !Task.isCancelled else { return }
            self.pendingCompletionTask = nil
            finalize()
        }
    }

    private func handleItemStarted(_ params: [String: Any]) {
        guard let item = params["item"] as? [String: Any] else { return }
        let type = item["type"] as? String ?? "other"
        if type == "reasoning" || type == "userMessage" { return }
        if type == "agentMessage" {
            if let itemID = item["id"] as? String {
                streamedAgentMessagePhases[itemID] = item["phase"] as? String ?? "final_answer"
            }
            if agentMessageText(from: item).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return
            }
        }
        emitActivity(startedEntry(for: item))
    }

    private func handleItemCompleted(_ params: [String: Any]) {
        guard let item = params["item"] as? [String: Any] else { return }

        let type = item["type"] as? String ?? "other"
        if type == "reasoning" || type == "userMessage" { return }

        if type == "agentMessage" {
            let itemID = item["id"] as? String
            let text = agentMessageText(from: item)
            let bufferedText = itemID.flatMap { streamedAgentMessageBuffers[$0] } ?? ""
            let finalText = text.isEmpty ? bufferedText : text
            if !finalText.isEmpty {
                lastAssistantMessage = finalText
            }
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
            lastAssistantMessage = updated
            emitActivity(
                CodexActivityEntry(
                    sourceID: "agent-\(itemID)",
                    groupID: "final-\(itemID)",
                    kind: .assistant,
                    blockKind: .final,
                    title: "Codex",
                    detail: updated,
                    detailStyle: .body
                )
            )
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
            let itemID = params["itemId"] as? String ?? params["callId"] as? String,
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

    private func handleFileChangeOutputDelta(_ params: [String: Any]) {
        guard
            let itemID = params["itemId"] as? String,
            let delta = params["delta"] as? String
        else {
            return
        }

        let updated = CodexActivityEntry.clippedText((fileChangeOutputBuffers[itemID] ?? "") + delta, maxCharacters: 16_000)
        fileChangeOutputBuffers[itemID] = updated

        emitActivity(
            CodexActivityEntry(
                sourceID: "file-output-\(itemID)",
                groupID: "patch-\(itemID)",
                kind: .tool,
                blockKind: .patch,
                title: "File Change Output",
                detail: updated,
                detailStyle: .monospaced
            )
        )
    }

    private func handleFileChangePatchUpdated(_ params: [String: Any]) {
        guard let itemID = params["itemId"] as? String else { return }
        let changes = params["changes"] as? [[String: Any]] ?? []

        emitActivity(
            CodexActivityEntry(
                sourceID: "file-change-\(itemID)",
                groupID: "patch-\(itemID)",
                kind: .tool,
                blockKind: .patch,
                title: "File Change Updated",
                detail: summarizeFileChanges(changes),
                detailStyle: .monospaced,
                relatedFiles: files(fromFileChanges: changes)
            )
        )
    }

    private func handleTurnDiffUpdated(_ params: [String: Any]) {
        let turnID = params["turnId"] as? String ?? activeTurnID ?? UUID().uuidString
        guard let diff = (params["diff"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !diff.isEmpty else {
            return
        }

        emitActivity(
            CodexActivityEntry(
                sourceID: "turn-diff-\(turnID)",
                groupID: "patch-\(turnID)",
                kind: .tool,
                blockKind: .patch,
                title: "Live Diff",
                detail: CodexActivityEntry.clippedText(diff, maxCharacters: 12_000),
                detailStyle: .monospaced
            )
        )
    }

    private func handleTurnPlanUpdated(_ params: [String: Any]) {
        let turnID = params["turnId"] as? String ?? activeTurnID ?? UUID().uuidString
        let explanation = (params["explanation"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let steps = params["plan"] as? [[String: Any]] ?? []
        let stepLines = steps.compactMap { step -> String? in
            guard let text = (step["step"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                return nil
            }
            let status = (step["status"] as? String ?? "pending").trimmingCharacters(in: .whitespacesAndNewlines)
            let prefix = planPrefix(for: status)
            return "\(prefix) \(text)"
        }
        let detail = ([explanation].compactMap { $0 } + stepLines).joined(separator: "\n")
        guard !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        emitActivity(
            CodexActivityEntry(
                sourceID: "turn-plan-\(turnID)",
                groupID: "plan-\(turnID)",
                kind: .assistant,
                blockKind: .reasoning,
                title: "Live Plan",
                detail: detail,
                detailStyle: .body
            )
        )
    }

    private func handleThreadTokenUsageUpdated(_ params: [String: Any]) {
        guard let tokenUsage = params["tokenUsage"] as? [String: Any] else { return }
        let turnID = params["turnId"] as? String ?? activeTurnID ?? UUID().uuidString
        let total = tokenUsage["total"] as? [String: Any]
        let last = tokenUsage["last"] as? [String: Any]
        let contextWindow = tokenUsage["modelContextWindow"] as? Int
        let totalTokens = total?["totalTokens"] as? Int
        let lastTokens = last?["totalTokens"] as? Int
        let reasoningTokens = last?["reasoningOutputTokens"] as? Int

        let lines = [
            totalTokens.map { "Total tokens: \($0)" },
            lastTokens.map { "Last turn: \($0)" },
            reasoningTokens.map { "Reasoning output: \($0)" },
            contextWindow.map { "Context window: \($0)" }
        ].compactMap { $0 }

        guard !lines.isEmpty else { return }

        emitActivity(
            CodexActivityEntry(
                sourceID: "token-usage-\(turnID)",
                groupID: "token-usage-\(turnID)",
                kind: .system,
                blockKind: .system,
                title: "Context Usage",
                detail: lines.joined(separator: "\n"),
                detailStyle: .body
            )
        )
    }

    private func handleWarningNotification(method: String, _ params: [String: Any]) {
        let message = params["message"] as? String
            ?? params["summary"] as? String
            ?? params["notice"] as? String
            ?? method
        let details = params["details"] as? String
        let path = params["path"] as? String
        let body = [message, details, path.map { "Path: \($0)" }]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")

        emitActivity(
            CodexActivityEntry(
                sourceID: "warning-\(method)-\(body.hashValue)",
                groupID: "warning-\(method)",
                kind: .warning,
                blockKind: .system,
                title: warningTitle(for: method),
                detail: body.isEmpty ? method : body
            )
        )
    }

    private func planPrefix(for status: String) -> String {
        switch status.lowercased() {
        case "completed", "complete", "done":
            return "- [x]"
        case "in_progress", "in-progress", "running":
            return "- [ ] In progress:"
        default:
            return "- [ ]"
        }
    }

    private func warningTitle(for method: String) -> String {
        switch method {
        case "guardianWarning":
            return "Codex Guardian Warning"
        case "configWarning":
            return "Codex Config Warning"
        case "deprecationNotice":
            return "Codex Deprecation Notice"
        default:
            return "Codex Warning"
        }
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
        guard !pendingSteers.isEmpty else { return }

        let steers = pendingSteers
        pendingSteers.removeAll()

        for steer in steers {
            await performSteer(prompt: steer.prompt, attachments: steer.attachments)
        }
    }

    private func resolvedAssistantMessage() -> String {
        let direct = lastAssistantMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        if !direct.isEmpty {
            return direct
        }

        let buffered = streamedAgentMessageBuffers
            .compactMap { key, value -> String? in
                let phase = streamedAgentMessagePhases[key] ?? "final_answer"
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard phase != "commentary", !trimmed.isEmpty else { return nil }
                return trimmed
            }
            .max(by: { $0.count < $1.count }) ?? ""

        return buffered
    }

    private func resetTurnState() {
        pendingCompletionTask?.cancel()
        pendingCompletionTask = nil
        currentPrompt = ""
        activeTurnID = nil
        lastAssistantMessage = ""
        isInterruptRequested = false
        pendingSteers = []
        pendingServerRequests = [:]
        streamedAgentMessagePhases = [:]
        streamedAgentMessageBuffers = [:]
        commandOutputBuffers = [:]
        fileChangeOutputBuffers = [:]
        reasoningSummaryBuffers = [:]
        planBuffers = [:]
    }

    private func commandDescription(for command: CodexTurnCommand) -> String {
        let model = command.modelOverride ?? "config default"
        let reasoning = command.reasoningEffort.title
        let speed = command.serviceTier.title
        let access = command.accessMode.title

        switch command {
        case .start:
            return "new session via app-server · model \(model) · think \(reasoning) · speed \(speed) · access \(access)"
        case let .resume(sessionID, _, _, _, _, _, _):
            return "resume \(sessionID) via app-server · model \(model) · think \(reasoning) · speed \(speed) · access \(access)"
        }
    }

    private func threadStartParams(for command: CodexTurnCommand) -> [String: Any] {
        var params: [String: Any] = [
            "cwd": workingDirectory,
            "approvalPolicy": command.accessMode.approvalPolicy,
            "approvalsReviewer": "user",
            "sandbox": command.accessMode.sandboxMode,
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
            "approvalPolicy": command.accessMode.approvalPolicy,
            "approvalsReviewer": "user",
            "sandbox": command.accessMode.sandboxMode,
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
            "input": command.appServerInputItems,
            "approvalPolicy": command.accessMode.approvalPolicy,
            "approvalsReviewer": "user",
            "sandboxPolicy": turnSandboxPolicy(for: command.accessMode),
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

    private func turnSandboxPolicy(for accessMode: CodexAccessMode) -> [String: Any] {
        switch accessMode {
        case .fullAccess:
            return ["type": "dangerFullAccess"]
        case .onRequest:
            return [
                "type": "workspaceWrite",
                "writableRoots": [workingDirectory],
                "networkAccess": true,
                "excludeTmpdirEnvVar": false,
                "excludeSlashTmp": false
            ]
        }
    }

    private func appServerInputItems(prompt: String, attachments: [CodexTurnAttachment]) -> [[String: Any]] {
        var items: [[String: Any]] = [
            ["type": "text", "text": prompt, "text_elements": []]
        ]
        items.append(contentsOf: attachments.compactMap(\.appServerInputItem))
        return items
    }

    private func userFacingPromptDetail(prompt: String, attachments: [CodexTurnAttachment]) -> String {
        guard !attachments.isEmpty else { return prompt }
        let names = attachments
            .map { $0.name ?? $0.path?.components(separatedBy: "/").last ?? $0.url ?? "imagen" }
            .joined(separator: ", ")
        return "\(prompt)\n\nAdjuntos: \(names)"
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
            let text = agentMessageText(from: item)
            return CodexActivityEntry(
                sourceID: itemID.map { "agent-\($0)" },
                groupID: itemID.map {
                    phase == "commentary" ? "reasoning-commentary-\($0)" : "final-\($0)"
                },
                kind: .assistant,
                blockKind: phase == "commentary" ? .reasoning : .final,
                title: phase == "commentary" ? "Codex Thinking" : "Codex",
                detail: text.isEmpty ? nil : text,
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

        case "contextCompaction", "contextcompaction", "context_compaction":
            return CodexActivityEntry(
                sourceID: itemID.map { "context-compaction-\($0)" },
                groupID: itemID.map { "context-compaction-\($0)" },
                kind: .system,
                blockKind: .system,
                title: "Contexto",
                detail: "Compactando contexto…",
                detailStyle: .body
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
            let bufferedText = itemID.flatMap { streamedAgentMessageBuffers[$0] } ?? ""
            let text = agentMessageText(from: item)
            let detail = text.isEmpty ? bufferedText : text
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
                detail: detail.isEmpty ? nil : detail,
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

        case "contextCompaction", "contextcompaction", "context_compaction":
            return CodexActivityEntry(
                sourceID: itemID.map { "context-compaction-\($0)" },
                groupID: itemID.map { "context-compaction-\($0)" },
                kind: .system,
                blockKind: .system,
                title: "Contexto",
                detail: "Contexto compactado",
                detailStyle: .body
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

    private func agentMessageText(from item: [String: Any]) -> String {
        if let text = item["text"] as? String {
            return text
        }

        if let content = item["content"] as? [[String: Any]] {
            return content.compactMap { part in
                part["text"] as? String
                    ?? part["content"] as? String
                    ?? part["markdown"] as? String
            }
            .joined()
        }

        if let message = item["message"] as? [String: Any] {
            return agentMessageText(from: message)
        }

        return ""
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

    private func files(fromPermissions permissions: [String: Any]) -> [CodexActivityFile] {
        guard let fileSystem = permissions["fileSystem"] as? [String: Any] else { return [] }
        var files: [CodexActivityFile] = []

        for key in ["read", "write"] {
            guard let paths = fileSystem[key] as? [String] else { continue }
            files.append(contentsOf: paths.map { CodexActivityFile(path: $0, kindLabel: key) })
        }

        if let entries = fileSystem["entries"] as? [[String: Any]] {
            for entry in entries {
                let access = entry["access"] as? String
                guard let path = permissionPathLabel(entry["path"] as? [String: Any]) else { continue }
                files.append(CodexActivityFile(path: path, kindLabel: access))
            }
        }

        return files
    }

    private func permissionsSummary(from permissions: [String: Any]) -> String? {
        var lines: [String] = []

        if let fileSystem = permissions["fileSystem"] as? [String: Any] {
            if let reads = fileSystem["read"] as? [String], !reads.isEmpty {
                lines.append("Read: \(reads.joined(separator: ", "))")
            }
            if let writes = fileSystem["write"] as? [String], !writes.isEmpty {
                lines.append("Write: \(writes.joined(separator: ", "))")
            }
            if let entries = fileSystem["entries"] as? [[String: Any]], !entries.isEmpty {
                let labels = entries.compactMap { entry -> String? in
                    guard let path = permissionPathLabel(entry["path"] as? [String: Any]) else { return nil }
                    let access = entry["access"] as? String ?? "access"
                    return "\(access): \(path)"
                }
                if !labels.isEmpty {
                    lines.append("Filesystem: \(labels.joined(separator: "; "))")
                }
            }
        }

        if let network = permissions["network"] as? [String: Any],
           let enabled = network["enabled"] as? Bool {
            lines.append("Network: \(enabled ? "enabled" : "disabled")")
        }

        if lines.isEmpty,
           let data = try? JSONSerialization.data(withJSONObject: permissions, options: [.prettyPrinted]),
           let text = String(data: data, encoding: .utf8),
           !text.isEmpty {
            lines.append(CodexActivityEntry.clippedText(text, maxCharacters: 2_000))
        }

        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    private func permissionPathLabel(_ payload: [String: Any]?) -> String? {
        guard let payload, let type = payload["type"] as? String else { return nil }

        switch type {
        case "path":
            return payload["path"] as? String
        case "glob_pattern":
            return payload["pattern"] as? String
        case "special":
            guard let value = payload["value"] as? [String: Any] else { return nil }
            if let kind = value["kind"] as? String {
                if let path = value["path"] as? String {
                    return "\(kind): \(path)"
                }
                return kind
            }
            return nil
        default:
            return nil
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
