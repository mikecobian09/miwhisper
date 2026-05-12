import AppKit
import Darwin
import Foundation
import Network

struct CompanionWorkspaceDescriptor: Codable, Identifiable {
    let id: String
    let name: String
    let path: String
    let isDefault: Bool
}

struct CompanionSessionSummary: Codable {
    let id: String
    let recordID: String?
    let title: String
    let threadID: String?
    let workingDirectory: String
    let workspaceID: String?
    let workspaceName: String
    let createdAt: Date?
    let updatedAt: Date
    let isBusy: Bool
    let latestResponse: String
    let hasLocalSession: Bool
    let accessMode: String?
    let liveState: String?
    let liveLabel: String?
}

struct CompanionSessionDetail: Codable {
    let session: CompanionSessionSummary
    let activity: [CodexActivityEntry]
    let live: CompanionLiveStatus
}

struct CompanionLiveStatus: Codable {
    let state: String
    let label: String
    let detail: String?
    let activeTitle: String?
    let activeDetail: String?
    let latestKind: String?
    let commandCount: Int
    let toolCount: Int
    let patchCount: Int
    let fileCount: Int
    let warningCount: Int
    let errorCount: Int
    let needsAttention: Bool
    let updatedAt: Date
}

struct CompanionBootstrapPayload: Codable {
    let appName: String
    let localURL: String
    let port: Int
    let workspaces: [CompanionWorkspaceDescriptor]
    let sessions: [CompanionSessionSummary]
}

struct CompanionFileSearchResponse: Encodable {
    let workspaceID: String
    let query: String
    let results: [CompanionFileIndexer.Result]
}

@MainActor
final class CompanionBridge {
    static let shared = CompanionBridge()

    let port = 6009

    private var server: CompanionHTTPServer?
    private let previewRegistry = CompanionPreviewRegistry()
    private let startedAt = Date()
    private var healthTimer: Timer?
    private var restartTask: Task<Void, Never>?
    private var intentionalStop = false
    private var restartCount = 0
    private var lastBridgeError: String?

    private init() {}

    func start() {
        intentionalStop = false
        guard server == nil else {
            startHealthMonitor()
            return
        }

        do {
            let httpServer = try CompanionHTTPServer(
                port: UInt16(port),
                handler: { [weak self] request in
                    guard let self else {
                        return .json(["error": "Companion server unavailable"], status: 503)
                    }
                    return await self.handle(request: request)
                }
            )
            httpServer.onFailure = { [weak self] reason in
                Task { @MainActor in
                    self?.handleServerFailure(reason: reason)
                }
            }
            try httpServer.start()
            server = httpServer
            lastBridgeError = nil
            startHealthMonitor()
            NSLog("[MiWhisper][Companion] listening on http://127.0.0.1:%d", port)
        } catch {
            lastBridgeError = error.localizedDescription
            NSLog("[MiWhisper][Companion] failed to start server error=%@", error.localizedDescription)
            scheduleRestart(reason: "start failed: \(error.localizedDescription)")
        }
    }

    func stop() {
        intentionalStop = true
        healthTimer?.invalidate()
        healthTimer = nil
        restartTask?.cancel()
        restartTask = nil
        server?.stop()
        server = nil
    }

    var localURLString: String {
        "http://127.0.0.1:\(port)"
    }

    private func startHealthMonitor() {
        guard healthTimer == nil else { return }
        healthTimer = Timer.scheduledTimer(withTimeInterval: 12, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.intentionalStop else { return }
                if self.server == nil {
                    self.scheduleRestart(reason: "health monitor found no active HTTP server")
                }
            }
        }
    }

    private func handleServerFailure(reason: String) {
        guard !intentionalStop else { return }
        lastBridgeError = reason
        NSLog("[MiWhisper][Companion] server failure: %@", reason)
        server?.stop()
        server = nil
        scheduleRestart(reason: reason)
    }

    private func scheduleRestart(reason: String) {
        guard !intentionalStop, restartTask == nil else { return }
        lastBridgeError = reason
        restartTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled, !self.intentionalStop else { return }
            self.restartTask = nil
            self.restartCount += 1
            self.server?.stop()
            self.server = nil
            self.start()
        }
    }

    private func handle(request: CompanionHTTPRequest) async -> CompanionHTTPResponse {
        switch (request.method, request.path) {
        case ("GET", "/"), ("GET", "/index.html"):
            return .html(CompanionPWA.indexHTML)

        case ("GET", "/app.js"):
            return .javascript(CompanionPWA.appJavaScript, cacheControl: "no-store")

        case ("GET", "/app.css"):
            return .css(CompanionPWA.appCSS, cacheControl: "no-store")

        case ("GET", "/manifest.webmanifest"):
            return .json(CompanionPWA.manifest(port: port))

        case ("GET", "/sw.js"):
            return .javascript(CompanionPWA.serviceWorkerJavaScript, cacheControl: "no-store")

        case ("GET", "/icon.svg"):
            return .svg(CompanionPWA.iconSVG)

        case ("GET", "/icon-maskable.svg"):
            return .svg(CompanionPWA.iconMaskableSVG)

        case ("GET", "/app-icon.png"):
            return .binary(
                CompanionPWA.appIconPNG(size: 256),
                status: 200,
                contentType: "image/png",
                cacheControl: "public, max-age=86400"
            )

        case ("GET", "/apple-touch-icon.png"), ("GET", "/apple-touch-icon-precomposed.png"):
            return .binary(
                CompanionPWA.appleTouchIconPNG(),
                status: 200,
                contentType: "image/png",
                cacheControl: "public, max-age=86400"
            )

        case ("GET", "/favicon.ico"):
            return .binary(
                CompanionPWA.appleTouchIconPNG(),
                status: 200,
                contentType: "image/png",
                cacheControl: "public, max-age=86400"
            )

        case ("GET", "/api/health"):
            return .json([
                "ok": true,
                "state": server == nil ? "stopped" : "running",
                "version": CompanionPWA.version,
                "port": port,
                "localURL": localURLString,
                "uptimeSeconds": Int(Date().timeIntervalSince(startedAt)),
                "sessions": CodexSessionManager.shared.allSessionRecords().count,
                "busySessions": CodexSessionManager.shared.allSessionRecords().filter { $0.isBusy == true }.count,
                "restartCount": restartCount,
                "lastBridgeError": lastBridgeError.map { $0 as Any } ?? NSNull(),
                "tts": [
                    "preferredProvider": "browser"
                ]
            ], cacheControl: "no-store")

        case ("GET", "/api/bootstrap"):
            let payload = CompanionBootstrapPayload(
                appName: "MiWhisper Companion",
                localURL: localURLString,
                port: port,
                workspaces: availableWorkspaces(),
                sessions: allSessionSummaries(workspaceID: request.queryValue(named: "workspaceID"))
            )
            return .json(payload, cacheControl: "no-store")

        case ("GET", "/api/workspaces"):
            return .json(availableWorkspaces(), cacheControl: "no-store")

        case ("GET", "/api/sessions"):
            return .json(
                allSessionSummaries(workspaceID: request.queryValue(named: "workspaceID")),
                cacheControl: "no-store"
            )

        case ("GET", "/api/sessions/stream"):
            return streamSessionListEvents(request: request)

        case ("POST", "/api/sessions"):
            return await createSession(request: request)

        case ("POST", "/api/sessions/open-thread"):
            return await openThreadSession(request: request)

        case ("POST", let path) where path.hasPrefix("/api/sessions/") && path.hasSuffix("/messages"):
            return await continueSession(request: request)

        case ("POST", let path) where path.hasPrefix("/api/sessions/") && path.contains("/approvals/"):
            return await resolveApproval(request: request)

        case ("POST", let path) where path.hasPrefix("/api/sessions/") && path.hasSuffix("/stop"):
            return await stopSession(request: request)

        case ("POST", let path) where path.hasPrefix("/api/sessions/") && path.hasSuffix("/focus"):
            return await focusSession(request: request)

        case ("GET", let path) where path.hasPrefix("/api/sessions/") && path.hasSuffix("/stream"):
            return streamSessionEvents(request: request)

        case ("PATCH", let path) where path.hasPrefix("/api/sessions/"):
            return renameSession(request: request)

        case ("DELETE", let path) where path.hasPrefix("/api/sessions/"):
            return deleteSession(request: request)

        case ("GET", let path) where path.hasPrefix("/api/sessions/"):
            return sessionDetail(request: request)

        case ("POST", "/api/voice/transcribe"):
            return await transcribeUploadedAudio(request: request)

        case ("GET", let path) where path.hasPrefix("/api/workspaces/") && path.hasSuffix("/files"):
            return searchWorkspaceFiles(request: request)

        case ("GET", "/api/files/raw"):
            return rawFile(request: request)

        case ("GET", "/preview"):
            return await renderedPreview(request: request)

        case ("GET", let path) where path.hasPrefix("/preview-assets/"):
            return await previewAsset(path: path)

        default:
            return .json(["error": "Not found"], status: 404)
        }
    }

    private func createSession(request: CompanionHTTPRequest) async -> CompanionHTTPResponse {
        guard let body = request.jsonObject as? [String: Any] else {
            return .json(["error": "Invalid JSON body"], status: 400)
        }

        let prompt = (body["prompt"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            return .json(["error": "Prompt is required"], status: 400)
        }

        let workspaceID = body["workspaceID"] as? String
        guard let workspace = workspaceForID(workspaceID) else {
            return .json(["error": "Unknown workspace"], status: 404)
        }

        let modelOverride = (body["modelOverride"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let reasoning = CompanionBridge.parseReasoningEffort(body["reasoningEffort"] as? String)
        let serviceTier = CompanionBridge.parseServiceTier(body["serviceTier"] as? String)
        let accessMode = CompanionBridge.parseAccessMode(body["accessMode"] as? String)
        let shouldOpenWindow = body["openWindow"] as? Bool ?? false
        let attachments: [CodexTurnAttachment]
        do {
            attachments = try companionAttachments(from: body)
        } catch {
            return .json(["error": error.localizedDescription], status: 400)
        }

        let recordID = CodexSessionManager.shared.createSession(
            prompt: prompt,
            executablePath: AppState.shared.codexPath,
            workingDirectory: workspace.path,
            modelOverride: modelOverride?.isEmpty == false ? modelOverride : AppState.shared.codexDefaultModel,
            reasoningEffort: reasoning ?? AppState.shared.codexReasoningEffort,
            serviceTier: serviceTier ?? AppState.shared.codexServiceTier,
            accessMode: accessMode ?? .fullAccess,
            shouldPresentWindow: shouldOpenWindow
        )

        if let record = CodexSessionManager.shared.sessionRecord(id: recordID) {
            do {
                try CodexSessionManager.shared.send(prompt: prompt, to: record.id, attachments: attachments)
            } catch {
                return .json(["error": error.localizedDescription], status: 500)
            }
        }

        guard let detail = sessionDetail(for: recordID) else {
            return .json(["error": "Could not create session"], status: 500)
        }
        return .json(detail, status: 201, cacheControl: "no-store")
    }

    private func openThreadSession(request: CompanionHTTPRequest) async -> CompanionHTTPResponse {
        guard let body = request.jsonObject as? [String: Any] else {
            return .json(["error": "Invalid JSON body"], status: 400)
        }

        let threadID = (body["threadID"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !threadID.isEmpty else {
            return .json(["error": "threadID is required"], status: 400)
        }

        let workspaces = codexWorkspaces()
        CodexThreadCatalog.shared.reload(workspaces: workspaces)

        guard let entry = CodexThreadCatalog.shared.entries.first(where: { $0.threadID == threadID }) else {
            return .json(["error": "Thread not found"], status: 404)
        }

        if let recordID = entry.recordID, let detail = sessionDetail(for: recordID) {
            return .json(detail, cacheControl: "no-store")
        }

        let normalizedModel = (body["modelOverride"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let modelOverride = normalizedModel?.isEmpty == false ? normalizedModel : AppState.shared.codexDefaultModel
        let reasoning = CompanionBridge.parseReasoningEffort(body["reasoningEffort"] as? String)
            ?? AppState.shared.codexReasoningEffort
        let serviceTier = CompanionBridge.parseServiceTier(body["serviceTier"] as? String)
            ?? AppState.shared.codexServiceTier
        let accessMode = CompanionBridge.parseAccessMode(body["accessMode"] as? String) ?? .fullAccess

        let recordID = CodexSessionManager.shared.openThread(
            threadID: threadID,
            title: entry.title,
            workingDirectory: entry.workingDirectory,
            executablePath: AppState.shared.codexPath,
            modelOverride: modelOverride?.isEmpty == false ? modelOverride : nil,
            reasoningEffort: reasoning,
            serviceTier: serviceTier,
            accessMode: accessMode
        )

        guard let detail = sessionDetail(for: recordID) else {
            return .json(["error": "Could not open thread"], status: 500)
        }

        return .json(detail, cacheControl: "no-store")
    }

    private func continueSession(request: CompanionHTTPRequest) async -> CompanionHTTPResponse {
        guard let recordID = recordID(fromSessionActionPath: request.path, suffix: "/messages") else {
            return .json(["error": "Invalid session path"], status: 400)
        }

        guard let body = request.jsonObject as? [String: Any] else {
            return .json(["error": "Invalid JSON body"], status: 400)
        }

        let prompt = (body["prompt"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            return .json(["error": "Prompt is required"], status: 400)
        }
        let reasoning = CompanionBridge.parseReasoningEffort(body["reasoningEffort"] as? String)
        let serviceTier = CompanionBridge.parseServiceTier(body["serviceTier"] as? String)
        let accessMode = CompanionBridge.parseAccessMode(body["accessMode"] as? String)
        let attachments: [CodexTurnAttachment]
        do {
            attachments = try companionAttachments(from: body)
        } catch {
            return .json(["error": error.localizedDescription], status: 400)
        }

        do {
            try CodexSessionManager.shared.send(
                prompt: prompt,
                to: recordID,
                reasoningEffort: reasoning,
                serviceTier: serviceTier,
                accessMode: accessMode,
                attachments: attachments
            )
        } catch {
            return .json(["error": error.localizedDescription], status: 500)
        }

        guard let detail = sessionDetail(for: recordID, allowHydration: false) else {
            return .json(["error": "Session not found"], status: 404)
        }
        return .json(detail, cacheControl: "no-store")
    }

    private func resolveApproval(request: CompanionHTTPRequest) async -> CompanionHTTPResponse {
        guard let approvalPath = parseApprovalActionPath(request.path) else {
            return .json(["error": "Invalid approval path"], status: 400)
        }

        guard let body = request.jsonObject as? [String: Any] else {
            return .json(["error": "Invalid JSON body"], status: 400)
        }

        let decision = (body["decision"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard ["accept", "acceptForSession", "decline", "cancel"].contains(decision) else {
            return .json(["error": "Invalid approval decision"], status: 400)
        }

        do {
            try CodexSessionManager.shared.resolveApproval(
                recordID: approvalPath.recordID,
                requestID: approvalPath.requestID,
                decision: decision
            )
        } catch {
            return .json(["error": error.localizedDescription], status: 500)
        }

        guard let detail = sessionDetail(for: approvalPath.recordID) else {
            return .json(["error": "Session not found"], status: 404)
        }
        return .json(detail, cacheControl: "no-store")
    }

    private func stopSession(request: CompanionHTTPRequest) async -> CompanionHTTPResponse {
        guard let recordID = recordID(fromSessionActionPath: request.path, suffix: "/stop") else {
            return .json(["error": "Invalid session path"], status: 400)
        }

        CodexSessionManager.shared.stop(recordID: recordID)
        guard let detail = sessionDetail(for: recordID) else {
            return .json(["error": "Session not found"], status: 404)
        }
        return .json(detail, cacheControl: "no-store")
    }

    private func focusSession(request: CompanionHTTPRequest) async -> CompanionHTTPResponse {
        guard let recordID = recordID(fromSessionActionPath: request.path, suffix: "/focus") else {
            return .json(["error": "Invalid session path"], status: 400)
        }

        CodexSessionManager.shared.focus(recordID: recordID)
        guard let detail = sessionDetail(for: recordID) else {
            return .json(["error": "Session not found"], status: 404)
        }
        return .json(detail, cacheControl: "no-store")
    }

    private func sessionDetail(request: CompanionHTTPRequest) -> CompanionHTTPResponse {
        let prefix = "/api/sessions/"
        guard request.path.hasPrefix(prefix) else {
            return .json(["error": "Invalid session path"], status: 400)
        }

        let value = String(request.path.dropFirst(prefix.count))
        guard let recordID = UUID(uuidString: value) else {
            return .json(["error": "Invalid session identifier"], status: 400)
        }

        guard let detail = sessionDetail(for: recordID) else {
            return .json(["error": "Session not found"], status: 404)
        }
        return .json(detail, cacheControl: "no-store")
    }

    private func renameSession(request: CompanionHTTPRequest) -> CompanionHTTPResponse {
        let prefix = "/api/sessions/"
        guard request.path.hasPrefix(prefix) else {
            return .json(["error": "Invalid session path"], status: 400)
        }
        let value = String(request.path.dropFirst(prefix.count))
        guard let recordID = UUID(uuidString: value) else {
            return .json(["error": "Invalid session identifier"], status: 400)
        }
        guard let body = request.jsonObject as? [String: Any] else {
            return .json(["error": "Invalid JSON body"], status: 400)
        }
        let rawTitle = (body["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawTitle.isEmpty else {
            return .json(["error": "Title is required"], status: 400)
        }
        let title = String(rawTitle.prefix(140))
        CodexSessionStore.shared.updateSession(id: recordID) { record in
            record.title = title
        }
        guard let detail = sessionDetail(for: recordID) else {
            return .json(["error": "Session not found"], status: 404)
        }
        return .json(detail, cacheControl: "no-store")
    }

    private func deleteSession(request: CompanionHTTPRequest) -> CompanionHTTPResponse {
        let prefix = "/api/sessions/"
        guard request.path.hasPrefix(prefix) else {
            return .json(["error": "Invalid session path"], status: 400)
        }
        let value = String(request.path.dropFirst(prefix.count))
        guard let recordID = UUID(uuidString: value) else {
            return .json(["error": "Invalid session identifier"], status: 400)
        }
        guard let record = CodexSessionStore.shared.session(id: recordID) else {
            return .json(["error": "Session not found"], status: 404)
        }
        if record.isBusy == true {
            return .json(["error": "Session is busy. Stop it before deleting."], status: 409)
        }
        CodexSessionManager.shared.stop(recordID: recordID)
        CodexSessionStore.shared.deleteSession(id: recordID)
        return .json(["ok": true, "deletedID": recordID.uuidString], cacheControl: "no-store")
    }

    private func streamSessionEvents(request: CompanionHTTPRequest) -> CompanionHTTPResponse {
        let prefix = "/api/sessions/"
        let suffix = "/stream"
        guard request.path.hasPrefix(prefix), request.path.hasSuffix(suffix) else {
            return .json(["error": "Invalid session path"], status: 400)
        }
        let raw = String(request.path.dropFirst(prefix.count).dropLast(suffix.count))
        guard let recordID = UUID(uuidString: raw) else {
            return .json(["error": "Invalid session identifier"], status: 400)
        }

        return .eventStream { writer in
            var lastPayload: String? = nil
            var missCount = 0
            var lastHeartbeat = Date()
            let started = Date()
            while !writer.closed {
                let payload: String? = await MainActor.run {
                    () -> String? in
                    guard let detail = CompanionBridge.shared.sessionDetail(for: recordID, workspaces: [], allowHydration: false) else {
                        return nil
                    }
                    let encoder = JSONEncoder()
                    encoder.dateEncodingStrategy = .iso8601
                    encoder.outputFormatting = [.sortedKeys]
                    if let data = try? encoder.encode(detail) {
                        return String(data: data, encoding: .utf8)
                    }
                    return nil
                }

                if let payload {
                    missCount = 0
                    if payload != lastPayload {
                        writer.send(event: "session", data: payload)
                        lastPayload = payload
                    }
                } else {
                    missCount += 1
                    if missCount >= 6 {
                        writer.send(event: "error", data: "{\"error\":\"session-not-found\"}")
                        break
                    }
                }

                if Date().timeIntervalSince(lastHeartbeat) > 15 {
                    writer.keepAlive()
                    lastHeartbeat = Date()
                }

                // Cap stream lifetime at 30 min; client reopens on its own.
                if Date().timeIntervalSince(started) > 1800 {
                    writer.send(event: "reconnect", data: "{}")
                    break
                }

                try? await Task.sleep(nanoseconds: 350_000_000)
            }
        }
    }

    private func streamSessionListEvents(request: CompanionHTTPRequest) -> CompanionHTTPResponse {
        let workspaceID = request.queryValue(named: "workspaceID")

        return .eventStream { writer in
            var lastPayload: String? = nil
            var lastHeartbeat = Date()
            let started = Date()

            while !writer.closed {
                let payload: String? = await MainActor.run {
                    let sessions = CompanionBridge.shared.allSessionSummaries(workspaceID: workspaceID)
                    let encoder = JSONEncoder()
                    encoder.dateEncodingStrategy = .iso8601
                    encoder.outputFormatting = [.sortedKeys]
                    if let data = try? encoder.encode(sessions) {
                        return String(data: data, encoding: .utf8)
                    }
                    return nil
                }

                if let payload, payload != lastPayload {
                    writer.send(event: "sessions", data: payload)
                    lastPayload = payload
                }

                if Date().timeIntervalSince(lastHeartbeat) > 15 {
                    writer.keepAlive()
                    lastHeartbeat = Date()
                }

                if Date().timeIntervalSince(started) > 1800 {
                    writer.send(event: "reconnect", data: "{}")
                    break
                }

                try? await Task.sleep(for: .milliseconds(2500))
            }
        }
    }

    private func searchWorkspaceFiles(request: CompanionHTTPRequest) -> CompanionHTTPResponse {
        let prefix = "/api/workspaces/"
        let suffix = "/files"
        guard request.path.hasPrefix(prefix), request.path.hasSuffix(suffix) else {
            return .json(["error": "Invalid workspace path"], status: 400)
        }
        let rawID = String(request.path.dropFirst(prefix.count).dropLast(suffix.count))
        guard let workspace = workspaceForID(rawID) else {
            return .json(["error": "Unknown workspace"], status: 404)
        }
        let query = (request.queryValue(named: "q") ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let limit = max(1, min(Int(request.queryValue(named: "limit") ?? "") ?? 20, 50))

        let results = CompanionFileIndexer.search(
            root: URL(fileURLWithPath: workspace.path),
            query: query,
            limit: limit
        )
        let payload = CompanionFileSearchResponse(workspaceID: workspace.id, query: query, results: results)
        return .json(payload, cacheControl: "no-store")
    }

    private func transcribeUploadedAudio(request: CompanionHTTPRequest) async -> CompanionHTTPResponse {
        guard !request.body.isEmpty else {
            return .json(["error": "Audio body is required"], status: 400)
        }

        let inputExtension = request.queryValue(named: "ext")
            ?? CompanionAudioNormalizer.preferredExtension(for: request.headerValue(named: "content-type"))
            ?? "m4a"

        NSLog(
            "[MiWhisper][CompanionVoice] upload sizeBytes=%ld contentType=%@ ext=%@",
            request.body.count,
            request.headerValue(named: "content-type") ?? "",
            inputExtension
        )

        do {
            let transcript = try await CompanionAudioNormalizer.transcribe(
                request.body,
                fileExtension: inputExtension
            )
            return .json(["transcript": transcript], cacheControl: "no-store")
        } catch {
            return .json(["error": error.localizedDescription], status: 500)
        }
    }

    private func rawFile(request: CompanionHTTPRequest) -> CompanionHTTPResponse {
        guard let path = request.queryValue(named: "path"), !path.isEmpty else {
            return .json(["error": "Missing path"], status: 400)
        }

        let fileURL = fileURLForPreviewPath(path, workspaceID: request.queryValue(named: "workspaceID"))
        guard isAllowedFile(url: fileURL) else {
            return .json(["error": "Path is outside the allowed roots"], status: 403)
        }
        guard !isSensitivePreviewPath(fileURL) else {
            return .json(["error": "Sensitive paths are not served by the companion bridge"], status: 403)
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return .json(["error": "File not found"], status: 404)
        }
        guard fileSize(at: fileURL) <= 50 * 1024 * 1024 else {
            return .json(["error": "File is too large for mobile preview"], status: 413)
        }

        do {
            let data = try Data(contentsOf: fileURL)
            return .binary(
                data,
                status: 200,
                contentType: CompanionFileMimeType.contentType(for: fileURL),
                cacheControl: "no-store",
                headers: [
                    "Content-Disposition": "inline; filename=\"\(fileURL.lastPathComponent.replacingOccurrences(of: "\"", with: ""))\""
                ]
            )
        } catch {
            return .json(["error": error.localizedDescription], status: 500)
        }
    }

    private func renderedPreview(request: CompanionHTTPRequest) async -> CompanionHTTPResponse {
        guard let path = request.queryValue(named: "path"), !path.isEmpty else {
            return .json(["error": "Missing path"], status: 400)
        }

        let fileURL = fileURLForPreviewPath(path, workspaceID: request.queryValue(named: "workspaceID"))
        guard isAllowedFile(url: fileURL) else {
            return .json(["error": "Path is outside the allowed roots"], status: 403)
        }
        guard !isSensitivePreviewPath(fileURL) else {
            return .json(["error": "Sensitive paths are not served by the companion bridge"], status: 403)
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return .json(["error": "File not found"], status: 404)
        }

        let fileExtension = fileURL.pathExtension.lowercased()

        if ["html", "htm"].contains(fileExtension) {
            let token = await previewRegistry.register(baseDirectory: fileURL.deletingLastPathComponent())
            let location = "/preview-assets/\(token)/\(fileURL.lastPathComponent.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? fileURL.lastPathComponent)"
            return .redirect(location: location)
        }

        if ["md", "markdown"].contains(fileExtension) {
            do {
                let markdown = try String(contentsOf: fileURL, encoding: .utf8)
                let rendered = CompanionMarkdownRenderer.renderDocument(
                    title: fileURL.lastPathComponent,
                    markdown: markdown
                )
                return .html(rendered, cacheControl: "no-store")
            } catch {
                return .json(["error": error.localizedDescription], status: 500)
            }
        }

        if CompanionFileMimeType.isInlinePreviewSupported(forExtension: fileExtension) {
            let rawPath = fileURL.path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? fileURL.path
            return .redirect(location: "/api/files/raw?path=\(rawPath)")
        }

        return .json(["error": "Preview is not supported for this file type"], status: 415)
    }

    private func previewAsset(path: String) async -> CompanionHTTPResponse {
        let prefix = "/preview-assets/"
        let remainder = String(path.dropFirst(prefix.count))
        let components = remainder.split(separator: "/", omittingEmptySubsequences: false)
        guard let token = components.first, !token.isEmpty else {
            return .json(["error": "Missing preview token"], status: 400)
        }

        let relativeComponents = components.dropFirst()
        let relativePath = relativeComponents.joined(separator: "/")
        let safeRelativePath = relativePath.removingPercentEncoding ?? relativePath

        guard let baseDirectory = await previewRegistry.baseDirectory(forToken: String(token)) else {
            return .json(["error": "Unknown preview token"], status: 404)
        }

        let candidateURL = baseDirectory
            .appendingPathComponent(safeRelativePath)
            .standardizedFileURL

        guard candidateURL.path.hasPrefix(baseDirectory.path) else {
            return .json(["error": "Preview path traversal blocked"], status: 403)
        }

        guard isAllowedFile(url: candidateURL) else {
            return .json(["error": "Path is outside the allowed roots"], status: 403)
        }

        do {
            let data = try Data(contentsOf: candidateURL)
            return .binary(
                data,
                status: 200,
                contentType: CompanionFileMimeType.contentType(for: candidateURL),
                cacheControl: "no-store"
            )
        } catch {
            return .json(["error": error.localizedDescription], status: 500)
        }
    }

    private func companionAttachments(from body: [String: Any]) throws -> [CodexTurnAttachment] {
        guard let rawAttachments = body["attachments"] as? [[String: Any]], !rawAttachments.isEmpty else {
            return []
        }

        guard rawAttachments.count <= 4 else {
            throw NSError(domain: "MiWhisper.Companion", code: 400, userInfo: [
                NSLocalizedDescriptionKey: "Puedes adjuntar hasta 4 imágenes por turno."
            ])
        }

        return try rawAttachments.compactMap { raw in
            let type = (raw["type"] as? String ?? "local_image").trimmingCharacters(in: .whitespacesAndNewlines)
            let name = (raw["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let mimeType = (raw["mimeType"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

            if type == "image", let imageURL = (raw["imageURL"] as? String ?? raw["image_url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !imageURL.isEmpty {
                return CodexTurnAttachment(kind: .image, path: nil, url: imageURL, name: name, mimeType: mimeType)
            }

            guard let data = try decodeAttachmentData(raw) else { return nil }
            guard data.count <= 15 * 1024 * 1024 else {
                throw NSError(domain: "MiWhisper.Companion", code: 413, userInfo: [
                    NSLocalizedDescriptionKey: "Una imagen adjunta supera 15 MB."
                ])
            }

            let directory = try companionAttachmentDirectory()
            let fileExtension = attachmentExtension(name: name, mimeType: mimeType)
            let safeName = sanitizeAttachmentName(name) ?? "image"
            let fileURL = directory.appendingPathComponent("\(UUID().uuidString)-\(safeName).\(fileExtension)")
            try data.write(to: fileURL, options: [.atomic])
            return CodexTurnAttachment(kind: .localImage, path: fileURL.path, url: nil, name: name, mimeType: mimeType)
        }
    }

    private func decodeAttachmentData(_ raw: [String: Any]) throws -> Data? {
        if let dataURL = raw["dataURL"] as? String ?? raw["dataUrl"] as? String,
           let comma = dataURL.firstIndex(of: ",") {
            let payload = String(dataURL[dataURL.index(after: comma)...])
            guard let data = Data(base64Encoded: payload) else {
                throw NSError(domain: "MiWhisper.Companion", code: 400, userInfo: [
                    NSLocalizedDescriptionKey: "No se pudo leer una imagen adjunta."
                ])
            }
            return data
        }

        if let base64 = raw["base64"] as? String {
            guard let data = Data(base64Encoded: base64) else {
                throw NSError(domain: "MiWhisper.Companion", code: 400, userInfo: [
                    NSLocalizedDescriptionKey: "No se pudo leer una imagen adjunta."
                ])
            }
            return data
        }

        return nil
    }

    private func companionAttachmentDirectory() throws -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let directory = base
            .appendingPathComponent("MiWhisper", isDirectory: true)
            .appendingPathComponent("CompanionAttachments", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func attachmentExtension(name: String?, mimeType: String?) -> String {
        if let ext = name.flatMap({ URL(fileURLWithPath: $0).pathExtension.lowercased() }),
           ["png", "jpg", "jpeg", "heic", "webp", "gif"].contains(ext) {
            return ext == "jpeg" ? "jpg" : ext
        }

        switch mimeType?.lowercased() {
        case "image/png": return "png"
        case "image/jpeg", "image/jpg": return "jpg"
        case "image/heic", "image/heif": return "heic"
        case "image/webp": return "webp"
        case "image/gif": return "gif"
        default: return "png"
        }
    }

    private func sanitizeAttachmentName(_ name: String?) -> String? {
        let stem = name.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }
            ?? "image"
        let cleaned = stem
            .map { char -> Character in
                char.isLetter || char.isNumber || char == "-" || char == "_" ? char : "-"
            }
            .reduce(into: "") { $0.append($1) }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        return cleaned.isEmpty ? nil : String(cleaned.prefix(48))
    }

    private func availableWorkspaces() -> [CompanionWorkspaceDescriptor] {
        codexWorkspaces().map {
            CompanionWorkspaceDescriptor(
                id: $0.id,
                name: $0.name,
                path: $0.path,
                isDefault: $0.isDefault
            )
        }
    }

    private func allSessionSummaries(workspaceID: String? = nil) -> [CompanionSessionSummary] {
        let workspaces = availableWorkspaces()
        let codexWorkspaces = codexWorkspaces()
        let selectedWorkspaceID = workspaceID?.trimmingCharacters(in: .whitespacesAndNewlines)
        CodexThreadCatalog.shared.reload(workspaces: codexWorkspaces)

        return CodexThreadCatalog.shared.entries.compactMap { entry in
            let session = summary(for: entry, workspaces: workspaces)
            guard let selectedWorkspaceID, selectedWorkspaceID.isEmpty == false else {
                return session
            }
            return session.workspaceID == selectedWorkspaceID ? session : nil
        }
    }

    private func sessionDetail(for recordID: UUID, allowHydration: Bool = true) -> CompanionSessionDetail? {
        let workspaces = availableWorkspaces()
        return sessionDetail(for: recordID, workspaces: workspaces, allowHydration: allowHydration)
    }

    private func sessionDetail(
        for recordID: UUID,
        workspaces: [CompanionWorkspaceDescriptor],
        allowHydration: Bool = true
    ) -> CompanionSessionDetail? {
        if allowHydration {
            CodexSessionManager.shared.hydrateSavedThreadIfNeeded(recordID: recordID)
        }

        guard let record = CodexSessionManager.shared.sessionRecord(id: recordID) else {
            return nil
        }
        let activity = companionActivity(for: record)

        return CompanionSessionDetail(
            session: summary(for: record, workspaces: workspaces),
            activity: activity,
            live: liveStatus(for: record, activity: activity)
        )
    }

    private func companionActivity(for record: CodexSessionRecord) -> [CodexActivityEntry] {
        let latest = record.latestResponse.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !latest.isEmpty else { return record.activity }

        let hasVisibleFinal = record.activity.contains { entry in
            entry.blockKind == .final &&
            !(entry.detail?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        }
        guard !hasVisibleFinal else { return record.activity }

        var activity = record.activity
        activity.append(
            CodexActivityEntry(
                groupID: "final-latest-\(record.id.uuidString)",
                kind: .assistant,
                blockKind: .final,
                title: "Codex",
                detail: latest,
                detailStyle: .body,
                createdAt: record.updatedAt
            )
        )
        return activity
    }

    private func liveStatus(for record: CodexSessionRecord, activity: [CodexActivityEntry]) -> CompanionLiveStatus {
        let readable = activity.filter { entry in
            let detail = entry.detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return !detail.isEmpty || !entry.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || entry.command != nil || !entry.relatedFiles.isEmpty
        }
        let latest = readable.last
        let latestKind = latest.map { $0.blockKind.rawValue }
        let warningCount = activity.filter { $0.kind == .warning }.count
        let errorCount = activity.filter { $0.kind == .error }.count
        let commandCount = activity.filter { $0.blockKind == .command }.count
        let toolCount = activity.filter { $0.blockKind == .tool }.count
        let patchEntries = activity.filter { $0.blockKind == .patch }
        let patchCount = patchEntries.count
        let fileCount = Set(activity.flatMap { $0.relatedFiles.map(\.path) }).count
        let needsAttention = activity.contains { entry in
            entry.kind == .warning &&
                (entry.title.localizedCaseInsensitiveContains("Needs Attention") ||
                 entry.title.localizedCaseInsensitiveContains("Approval Requested"))
        }

        let state: String
        let label: String
        let detail: String?

        if errorCount > 0, latest?.kind == .error {
            state = "error"
            label = "Codex necesita revisión"
            detail = latest?.detail ?? latest?.title
        } else if needsAttention {
            state = "attention"
            label = "Esperando atención"
            detail = latest?.detail ?? "Codex pidió una acción que todavía no puede resolverse desde la PWA."
        } else if record.isBusy == true {
            switch latest?.blockKind {
            case .command:
                state = "command"
                label = "Ejecutando comando"
                detail = latest?.command ?? latest?.detail
            case .tool:
                state = "tool"
                label = "Usando herramienta"
                detail = latest?.detail ?? latest?.title
            case .patch:
                state = "patch"
                label = "Editando archivos"
                detail = latest?.detail ?? latest?.title
            case .reasoning:
                state = "thinking"
                label = "Pensando"
                detail = latest?.detail
            case .final:
                state = "streaming"
                label = "Transmitiendo respuesta"
                detail = latest?.detail
            default:
                state = "running"
                label = "Codex trabajando"
                detail = latest?.detail ?? latest?.title
            }
        } else if let latest, latest.blockKind == .final {
            state = "ready"
            label = "Listo"
            detail = latest.detail
        } else if !record.latestResponse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            state = "ready"
            label = "Listo"
            detail = record.latestResponse
        } else {
            state = "idle"
            label = record.threadID == nil ? "Nuevo thread" : "Thread listo"
            detail = record.threadID
        }

        let activeDetail = (detail ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n")
            .prefix(2)
            .joined(separator: " ")

        return CompanionLiveStatus(
            state: state,
            label: label,
            detail: activeDetail.isEmpty ? nil : String(activeDetail.prefix(220)),
            activeTitle: latest?.title,
            activeDetail: activeDetail.isEmpty ? nil : String(activeDetail.prefix(360)),
            latestKind: latestKind,
            commandCount: commandCount,
            toolCount: toolCount,
            patchCount: patchCount,
            fileCount: fileCount,
            warningCount: warningCount,
            errorCount: errorCount,
            needsAttention: needsAttention,
            updatedAt: latest?.createdAt ?? record.updatedAt
        )
    }

    private func summary(
        for record: CodexSessionRecord,
        workspaces: [CompanionWorkspaceDescriptor]
    ) -> CompanionSessionSummary {
        let workspaceName = workspaces.first(where: { record.workingDirectory.hasPrefix($0.path) })?.name
            ?? workspaces.first(where: { record.workingDirectory == $0.path })?.name
            ?? URL(fileURLWithPath: record.workingDirectory).lastPathComponent
        let workspaceID = workspaces.first(where: { record.workingDirectory == $0.path || record.workingDirectory.hasPrefix($0.path + "/") })?.id
        let activity = companionActivity(for: record)
        let live = liveStatus(for: record, activity: activity)

        return CompanionSessionSummary(
            id: record.id.uuidString,
            recordID: record.id.uuidString,
            title: record.title,
            threadID: record.threadID,
            workingDirectory: record.workingDirectory,
            workspaceID: workspaceID,
            workspaceName: workspaceName,
            createdAt: record.createdAt,
            updatedAt: record.updatedAt,
            isBusy: record.isBusy ?? false,
            latestResponse: record.latestResponse,
            hasLocalSession: true,
            accessMode: (record.accessMode ?? .fullAccess).rawValue,
            liveState: live.state,
            liveLabel: live.label
        )
    }

    private func summary(
        for entry: CodexThreadListEntry,
        workspaces: [CompanionWorkspaceDescriptor]
    ) -> CompanionSessionSummary {
        let workspaceMatch = workspaces.first {
            entry.workingDirectory == $0.path || entry.workingDirectory.hasPrefix($0.path + "/")
        }

        let recordID = entry.recordID?.uuidString
        let accessMode = entry.recordID
            .flatMap { CodexSessionManager.shared.sessionRecord(id: $0)?.accessMode }
            ?? .fullAccess

        return CompanionSessionSummary(
            id: recordID ?? entry.threadID ?? entry.id,
            recordID: recordID,
            title: entry.title,
            threadID: entry.threadID,
            workingDirectory: entry.workingDirectory,
            workspaceID: workspaceMatch?.id,
            workspaceName: workspaceMatch?.name ?? entry.workspaceName,
            createdAt: entry.createdAt,
            updatedAt: entry.updatedAt,
            isBusy: entry.isBusy,
            latestResponse: entry.latestResponse,
            hasLocalSession: entry.recordID != nil,
            accessMode: entry.recordID == nil ? nil : accessMode.rawValue,
            liveState: entry.isBusy ? "running" : (entry.latestResponse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "idle" : "ready"),
            liveLabel: entry.isBusy ? "Codex trabajando" : (entry.latestResponse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Thread listo" : "Listo")
        )
    }

    private func workspaceForID(_ workspaceID: String?) -> CompanionWorkspaceDescriptor? {
        let workspaces = availableWorkspaces()
        guard let workspaceID, !workspaceID.isEmpty else {
            return workspaces.first(where: \.isDefault) ?? workspaces.first
        }
        return workspaces.first { $0.id == workspaceID }
    }

    private func codexWorkspaces() -> [CodexWorkspaceDescriptor] {
        CodexWorkspaceCatalog.availableWorkspaces(defaultRoot: AppState.shared.workspaceRoot)
    }

    private func allowedRoots() -> [String] {
        var roots = availableWorkspaces().map(\.path)
        roots.append(AppState.shared.companionArtifactRoot)
        return roots.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
    }

    private func fileURLForPreviewPath(_ rawPath: String, workspaceID: String?) -> URL {
        var path = rawPath.removingPercentEncoding ?? rawPath
        if path.hasPrefix("file://") {
            path = String(path.dropFirst("file://".count))
        }
        if path.hasPrefix("~/") {
            path = NSHomeDirectory() + String(path.dropFirst(1))
        }
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path).standardizedFileURL
        }

        let basePath = workspaceForID(workspaceID)?.path
            ?? availableWorkspaces().first(where: \.isDefault)?.path
            ?? AppState.shared.workspaceRoot
        return URL(fileURLWithPath: basePath)
            .appendingPathComponent(path)
            .standardizedFileURL
    }

    private func isAllowedFile(url: URL) -> Bool {
        let filePath = url.standardizedFileURL.path
        return allowedRoots().contains(where: { root in
            filePath == root || filePath.hasPrefix(root + "/")
        })
    }

    private func isSensitivePreviewPath(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let home = NSHomeDirectory()
        let blockedPrefixes = [
            "\(home)/.ssh/",
            "\(home)/.gnupg/",
            "\(home)/.aws/",
            "\(home)/.config/",
            "\(home)/.codex/auth",
            "\(home)/Library/Keychains/",
            "\(home)/Library/Application Support/",
        ]
        if blockedPrefixes.contains(where: { path == String($0.dropLast()) || path.hasPrefix($0) }) {
            return true
        }
        let lowerName = url.lastPathComponent.lowercased()
        if lowerName == ".env" || lowerName.hasPrefix(".env.") { return true }
        if lowerName.contains("id_rsa") || lowerName.contains("id_ed25519") { return true }
        if lowerName.hasSuffix(".pem") || lowerName.hasSuffix(".p12") || lowerName.hasSuffix(".key") { return true }
        return false
    }

    private func fileSize(at url: URL) -> Int64 {
        let attributes = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }

    private func recordID(fromSessionActionPath path: String, suffix: String) -> UUID? {
        let prefix = "/api/sessions/"
        guard path.hasPrefix(prefix), path.hasSuffix(suffix) else { return nil }
        let rawValue = String(path.dropFirst(prefix.count).dropLast(suffix.count))
        return UUID(uuidString: rawValue)
    }

    private func parseApprovalActionPath(_ path: String) -> (recordID: UUID, requestID: Int)? {
        let prefix = "/api/sessions/"
        guard path.hasPrefix(prefix) else { return nil }
        let rest = String(path.dropFirst(prefix.count))
        let parts = rest.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count == 3,
              parts[1] == "approvals",
              let recordID = UUID(uuidString: String(parts[0])),
              let requestID = Int(parts[2])
        else {
            return nil
        }
        return (recordID, requestID)
    }

    private static func parseReasoningEffort(_ rawValue: String?) -> CodexReasoningEffort? {
        guard let rawValue else { return nil }
        return CodexReasoningEffort(rawValue: rawValue)
    }

    private static func parseServiceTier(_ rawValue: String?) -> CodexServiceTier? {
        guard let rawValue else { return nil }
        return CodexServiceTier(rawValue: rawValue)
    }

    private static func parseAccessMode(_ rawValue: String?) -> CodexAccessMode? {
        guard let rawValue else { return nil }
        switch rawValue {
        case CodexAccessMode.fullAccess.rawValue, "full", "danger-full-access":
            return .fullAccess
        case CodexAccessMode.onRequest.rawValue, "on-request", "workspace-write":
            return .onRequest
        default:
            return nil
        }
    }
}

actor CompanionPreviewRegistry {
    private var tokensByBasePath: [String: String] = [:]
    private var basePathsByToken: [String: URL] = [:]

    func register(baseDirectory: URL) -> String {
        let normalized = baseDirectory.standardizedFileURL.path
        if let existing = tokensByBasePath[normalized] {
            return existing
        }

        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        tokensByBasePath[normalized] = token
        basePathsByToken[token] = baseDirectory.standardizedFileURL
        return token
    }

    func baseDirectory(forToken token: String) -> URL? {
        basePathsByToken[token]
    }
}

enum CompanionAudioNormalizer {
    static func transcribe(_ data: Data, fileExtension: String) async throws -> String {
        let inputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("miwhisper-upload-\(UUID().uuidString)")
            .appendingPathExtension(fileExtension)
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("miwhisper-upload-\(UUID().uuidString)")
            .appendingPathExtension("wav")

        try data.write(to: inputURL)

        defer {
            try? FileManager.default.removeItem(at: inputURL)
            try? FileManager.default.removeItem(at: outputURL)
        }

        try await normalize(inputURL: inputURL, outputURL: outputURL)
        return try await AppState.shared.transcribeUploadedAudioFile(at: outputURL)
    }

    static func preferredExtension(for contentType: String?) -> String? {
        guard let contentType else { return nil }

        switch contentType.lowercased() {
        case let value where value.contains("audio/wav"), let value where value.contains("audio/x-wav"):
            return "wav"
        case let value where value.contains("audio/mp4"), let value where value.contains("audio/x-m4a"), let value where value.contains("audio/m4a"):
            return "m4a"
        case let value where value.contains("audio/aac"):
            return "aac"
        case let value where value.contains("audio/webm"):
            return "webm"
        default:
            return nil
        }
    }

    private static func normalize(inputURL: URL, outputURL: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            if inputURL.pathExtension.lowercased() == "webm" {
                throw WhisperError.runtimeFailed("The PWA uploaded WebM audio, but macOS cannot normalize WebM with afconvert. Reload the PWA so it records as MP4/M4A.")
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
            process.arguments = [
                "-f", "WAVE",
                "-d", "LEI16@16000",
                "-c", "1",
                inputURL.path,
                outputURL.path,
            ]

            let stderrPipe = Pipe()
            process.standardError = stderrPipe

            try process.run()
            process.waitUntilExit()

            if process.terminationStatus != 0 {
                let errorData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let message = String(data: errorData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw WhisperError.runtimeFailed(message?.isEmpty == false ? message! : "afconvert failed to normalize the uploaded audio.")
            }

            guard FileManager.default.fileExists(atPath: outputURL.path) else {
                throw WhisperError.runtimeFailed("afconvert finished but did not create a normalized WAV file at \(outputURL.path).")
            }
        }.value
    }
}

enum CompanionFileIndexer {
    private static let ignoredDirNames: Set<String> = [
        ".git", ".hg", ".svn", "node_modules", "Pods", ".build", "DerivedData",
        "build", "dist", ".next", ".cache", "Carthage", ".venv", "venv", "__pycache__",
        ".idea", ".vscode", ".gradle", ".turbo", "target", "out", ".DS_Store",
    ]
    private static let ignoredExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "ico", "pdf",
        "zip", "gz", "tar", "bz2", "7z", "dmg", "pkg",
        "mp3", "mp4", "mov", "m4a", "wav", "aac",
        "woff", "woff2", "ttf", "otf", "eot",
        "o", "a", "dylib", "so", "class", "pyc",
    ]
    private static let maxFilesToScan = 4_000
    private static let maxDepth = 10
    private static let scanTimeBudget: TimeInterval = 0.55

    struct Result: Encodable {
        let path: String
        let relativePath: String
        let displayName: String
        let score: Int
        let kind: String
    }

    static func search(root: URL, query: String, limit: Int) -> [Result] {
        let started = Date()
        let normalizedQuery = query.lowercased()
        let rootPath = root.standardizedFileURL.path
        let fm = FileManager.default

        var candidates: [(url: URL, rel: String, score: Int)] = []
        candidates.reserveCapacity(128)

        var stack: [(url: URL, depth: Int)] = [(root.standardizedFileURL, 0)]
        var scanned = 0

        while let current = stack.popLast() {
            if scanned >= maxFilesToScan { break }
            if Date().timeIntervalSince(started) > scanTimeBudget { break }

            let items: [URL]
            do {
                items = try fm.contentsOfDirectory(
                    at: current.url,
                    includingPropertiesForKeys: [.isDirectoryKey, .isHiddenKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                )
            } catch {
                continue
            }

            for item in items {
                if scanned >= maxFilesToScan { break }
                scanned += 1
                let name = item.lastPathComponent
                var isDir: ObjCBool = false
                fm.fileExists(atPath: item.path, isDirectory: &isDir)
                if isDir.boolValue {
                    if ignoredDirNames.contains(name) { continue }
                    if name.hasPrefix(".") { continue }
                    if current.depth + 1 < maxDepth {
                        stack.append((item, current.depth + 1))
                    }
                    continue
                }
                let ext = item.pathExtension.lowercased()
                if ignoredExtensions.contains(ext) { continue }

                var relative = item.path
                if relative.hasPrefix(rootPath + "/") {
                    relative = String(relative.dropFirst(rootPath.count + 1))
                } else if relative == rootPath {
                    relative = item.lastPathComponent
                }

                let score = fuzzyScore(query: normalizedQuery, path: relative.lowercased(), name: name.lowercased())
                if normalizedQuery.isEmpty || score > 0 {
                    candidates.append((item, relative, score))
                }
            }
        }

        let sorted = candidates
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.rel.count < rhs.rel.count
            }
            .prefix(limit)

        return sorted.map { candidate in
            Result(
                path: candidate.url.path,
                relativePath: candidate.rel,
                displayName: candidate.url.lastPathComponent,
                score: candidate.score,
                kind: candidate.url.pathExtension.lowercased()
            )
        }
    }

    private static func fuzzyScore(query: String, path: String, name: String) -> Int {
        if query.isEmpty { return 1 }
        if path == query { return 100_000 }
        if name == query { return 90_000 }
        if name.hasPrefix(query) { return 70_000 - name.count }
        if path.hasSuffix(query) { return 50_000 - path.count }
        if name.contains(query) { return 30_000 - name.count }
        if path.contains(query) { return 15_000 - path.count }

        // subsequence match
        var qi = query.startIndex
        var lastMatchIndex: Int = -1
        var runs = 0
        var inRun = false
        var matchCount = 0
        for (idx, ch) in path.enumerated() {
            if qi < query.endIndex, ch == query[qi] {
                matchCount += 1
                qi = query.index(after: qi)
                if idx == lastMatchIndex + 1 { if !inRun { runs += 1; inRun = true } }
                else { inRun = false }
                lastMatchIndex = idx
            }
        }
        if qi == query.endIndex {
            return 5_000 + runs * 50 + matchCount - path.count
        }
        return 0
    }
}

struct CompanionFileMimeType {
    private static let textExtensions: Set<String> = [
        "bash", "c", "cc", "conf", "cpp", "cs", "css", "csv", "cxx", "diff", "env", "fish",
        "go", "h", "hpp", "htm", "html", "ini", "java", "js", "json", "jsx", "kt", "lock", "mjs",
        "log", "m", "markdown", "md", "mm", "patch", "php", "plist", "py", "rb", "rs",
        "sh", "sql", "swift", "toml", "ts", "tsx", "tsv", "txt", "webmanifest", "xml", "yaml",
        "yml", "zsh",
    ]

    private static let inlineBinaryExtensions: Set<String> = [
        "gif", "jpeg", "jpg", "m4a", "mov", "mp3", "mp4", "pdf", "png", "svg", "wav", "webp", "zip",
    ]

    static func isInlinePreviewSupported(forExtension fileExtension: String) -> Bool {
        let normalized = fileExtension.lowercased()
        return textExtensions.contains(normalized) || inlineBinaryExtensions.contains(normalized)
    }

    static func contentType(for fileURL: URL) -> String {
        switch fileURL.pathExtension.lowercased() {
        case "html", "htm":
            return "text/html; charset=utf-8"
        case "css":
            return "text/css; charset=utf-8"
        case "js":
            return "application/javascript; charset=utf-8"
        case "mjs", "jsx", "ts", "tsx":
            return "text/plain; charset=utf-8"
        case "json", "webmanifest":
            return "application/json; charset=utf-8"
        case "csv":
            return "text/csv; charset=utf-8"
        case "tsv":
            return "text/tab-separated-values; charset=utf-8"
        case "md", "markdown", "txt", "log", "diff", "patch", "swift", "py", "rb", "go", "rs",
             "java", "kt", "c", "h", "m", "mm", "cpp", "cc", "cxx", "hpp", "cs", "php",
             "sh", "bash", "zsh", "fish", "yaml", "yml", "xml", "plist", "sql", "toml",
             "ini", "conf", "env", "lock":
            return "text/plain; charset=utf-8"
        case "svg":
            return "image/svg+xml"
        case "png":
            return "image/png"
        case "jpg", "jpeg":
            return "image/jpeg"
        case "gif":
            return "image/gif"
        case "webp":
            return "image/webp"
        case "pdf":
            return "application/pdf"
        case "mp4":
            return "video/mp4"
        case "mov":
            return "video/quicktime"
        case "m4a":
            return "audio/mp4"
        case "mp3":
            return "audio/mpeg"
        case "wav":
            return "audio/wav"
        case "zip":
            return "application/zip"
        default:
            return "application/octet-stream"
        }
    }
}

enum CompanionMarkdownRenderer {
    static func renderDocument(title: String, markdown: String) -> String {
        let body = render(markdown: markdown)
        return """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>\(escapeHTML(title))</title>
          <style>
            :root {
              color-scheme: light dark;
              --bg: #f7f7f5;
              --panel: rgba(255,255,255,0.88);
              --text: #0d0d0d;
              --muted: #6c6c67;
              --accent: #0d0d0d;
              --border: rgba(13, 13, 13, 0.12);
            }
            @media (prefers-color-scheme: dark) {
              :root {
                --bg: #0f0f0f;
                --panel: rgba(23,23,23,0.88);
                --text: #f4f4f2;
                --muted: #a3a39c;
                --border: rgba(148, 163, 184, 0.2);
              }
            }
            * { box-sizing: border-box; }
            html, body {
              max-width: 100%;
              overflow-x: hidden;
            }
            body {
              margin: 0;
              padding: clamp(10px, 2.4vw, 18px);
              font: 16px/1.65 "Avenir Next", ui-rounded, system-ui, sans-serif;
              color: var(--text);
              background:
                radial-gradient(circle at top right, rgba(13,148,136,0.16), transparent 34%),
                radial-gradient(circle at bottom left, rgba(245,158,11,0.12), transparent 28%),
                var(--bg);
            }
            article {
              max-width: 980px;
              margin: 0 auto;
              padding: clamp(14px, 3vw, 22px);
              border: 1px solid var(--border);
              border-radius: 16px;
              background: var(--panel);
              backdrop-filter: blur(14px);
              box-shadow: 0 28px 60px rgba(15, 23, 42, 0.14);
              min-width: 0;
              overflow-wrap: anywhere;
            }
            article > :first-child { margin-top: 0; }
            article > :last-child { margin-bottom: 0; }
            p, li, th, td {
              overflow-wrap: anywhere;
              word-break: break-word;
            }
            pre, code {
              font-family: "SF Mono", "IBM Plex Mono", ui-monospace, monospace;
            }
            pre {
              overflow-x: hidden;
              white-space: pre-wrap;
              overflow-wrap: anywhere;
              padding: 14px 16px;
              border-radius: 10px;
              background: rgba(15, 23, 42, 0.08);
            }
            table {
              width: 100%;
              table-layout: fixed;
              border-collapse: collapse;
              margin: 1rem 0;
              font-size: 0.92rem;
              border: 1px solid var(--border);
              border-radius: 10px;
              overflow: hidden;
            }
            th, td {
              padding: 8px 10px;
              border: 1px solid var(--border);
              vertical-align: top;
              text-align: left;
            }
            th {
              background: rgba(15, 23, 42, 0.06);
              font-weight: 700;
            }
            blockquote {
              margin: 1.25rem 0;
              padding-left: 1rem;
              border-left: 4px solid var(--accent);
              color: var(--muted);
            }
            a { color: var(--accent); }
            img, iframe { max-width: 100%; }
          </style>
        </head>
        <body>
          <article>\(body)</article>
        </body>
        </html>
        """
    }

    static func render(markdown: String) -> String {
        let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")

        var html: [String] = []
        var paragraphLines: [String] = []
        var listItems: [String] = []
        var codeFenceLines: [String] = []
        var inCodeFence = false

        func flushParagraph() {
            guard !paragraphLines.isEmpty else { return }
            let text = paragraphLines.joined(separator: " ")
            html.append("<p>\(inline(text))</p>")
            paragraphLines.removeAll(keepingCapacity: true)
        }

        func flushList() {
            guard !listItems.isEmpty else { return }
            let items = listItems.map { "<li>\(inline($0))</li>" }.joined()
            html.append("<ul>\(items)</ul>")
            listItems.removeAll(keepingCapacity: true)
        }

        func flushCodeFence() {
            guard !codeFenceLines.isEmpty else { return }
            let text = escapeHTML(codeFenceLines.joined(separator: "\n"))
            html.append("<pre><code>\(text)</code></pre>")
            codeFenceLines.removeAll(keepingCapacity: true)
        }

        var index = 0
        while index < lines.count {
            let line = lines[index]
            if line.hasPrefix("```") {
                if inCodeFence {
                    flushCodeFence()
                } else {
                    flushParagraph()
                    flushList()
                }
                inCodeFence.toggle()
                index += 1
                continue
            }

            if inCodeFence {
                codeFenceLines.append(line)
                index += 1
                continue
            }

            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flushParagraph()
                flushList()
                index += 1
                continue
            }

            if let headingLevel = headingLevel(for: line) {
                flushParagraph()
                flushList()
                let text = line.drop { $0 == "#" || $0 == " " }
                html.append("<h\(headingLevel)>\(inline(String(text)))</h\(headingLevel)>")
                index += 1
                continue
            }

            if index + 1 < lines.count,
               line.contains("|"),
               isMarkdownTableSeparator(lines[index + 1]) {
                flushParagraph()
                flushList()

                let header = splitMarkdownTableRow(line)
                let alignments = tableAlignments(from: splitMarkdownTableRow(lines[index + 1]))
                var rows: [[String]] = []
                index += 2

                while index < lines.count {
                    let rowLine = lines[index]
                    guard rowLine.contains("|"), !rowLine.trimmingCharacters(in: .whitespaces).isEmpty else { break }
                    rows.append(splitMarkdownTableRow(rowLine))
                    index += 1
                }

                html.append(renderTable(header: header, alignments: alignments, rows: rows))
                continue
            }

            if line.hasPrefix(">") {
                flushParagraph()
                flushList()
                let text = line.drop { $0 == ">" || $0 == " " }
                html.append("<blockquote>\(inline(String(text)))</blockquote>")
                index += 1
                continue
            }

            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                flushParagraph()
                listItems.append(String(line.dropFirst(2)))
                index += 1
                continue
            }

            paragraphLines.append(line.trimmingCharacters(in: .whitespaces))
            index += 1
        }

        flushParagraph()
        flushList()
        flushCodeFence()

        return html.joined(separator: "\n")
    }

    private static func headingLevel(for line: String) -> Int? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("#") else { return nil }
        let count = trimmed.prefix { $0 == "#" }.count
        guard (1...6).contains(count), trimmed.dropFirst(count).first == " " else { return nil }
        return count
    }

    private static func renderTable(header: [String], alignments: [String?], rows: [[String]]) -> String {
        let columnCount = max(header.count, rows.map(\.count).max() ?? 0)
        guard columnCount > 0 else { return "" }

        func normalized(_ cells: [String]) -> [String] {
            if cells.count >= columnCount { return Array(cells.prefix(columnCount)) }
            return cells + Array(repeating: "", count: columnCount - cells.count)
        }

        func alignmentAttribute(for index: Int) -> String {
            guard index < alignments.count, let alignment = alignments[index] else { return "" }
            return " style=\"text-align: \(alignment)\""
        }

        let headerCells = normalized(header).enumerated().map { index, cell in
            "<th\(alignmentAttribute(for: index))>\(inline(cell))</th>"
        }.joined()
        let bodyRows = rows.map { row in
            let cells = normalized(row).enumerated().map { index, cell in
                "<td\(alignmentAttribute(for: index))>\(inline(cell))</td>"
            }.joined()
            return "<tr>\(cells)</tr>"
        }.joined()

        return "<table><thead><tr>\(headerCells)</tr></thead><tbody>\(bodyRows)</tbody></table>"
    }

    private static func tableAlignments(from cells: [String]) -> [String?] {
        cells.map { cell in
            let trimmed = cell.trimmingCharacters(in: .whitespaces)
            let left = trimmed.hasPrefix(":")
            let right = trimmed.hasSuffix(":")
            if left && right { return "center" }
            if right { return "right" }
            if left { return "left" }
            return nil
        }
    }

    private static func isMarkdownTableSeparator(_ line: String) -> Bool {
        let cells = splitMarkdownTableRow(line)
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            let trimmed = cell.trimmingCharacters(in: .whitespaces)
            guard trimmed.count >= 3 else { return false }
            let withoutColons = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            return !withoutColons.isEmpty && withoutColons.allSatisfy { $0 == "-" }
        }
    }

    private static func splitMarkdownTableRow(_ line: String) -> [String] {
        var cells: [String] = []
        var current = ""
        var escaped = false
        var inCode = false

        for character in line {
            if escaped {
                current.append(character)
                escaped = false
                continue
            }

            if character == "\\" {
                escaped = true
                continue
            }

            if character == "`" {
                inCode.toggle()
                current.append(character)
                continue
            }

            if character == "|", !inCode {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
                continue
            }

            current.append(character)
        }

        if escaped { current.append("\\") }
        cells.append(current.trimmingCharacters(in: .whitespaces))

        if cells.first?.isEmpty == true { cells.removeFirst() }
        if cells.last?.isEmpty == true { cells.removeLast() }
        return cells
    }

    private static func inline(_ text: String) -> String {
        var output = escapeHTML(text)

        let replacements: [(String, String)] = [
            ("**", "strong"),
            ("__", "strong"),
            ("`", "code"),
        ]

        for (marker, tag) in replacements {
            output = replacePairs(in: output, marker: marker, tag: tag)
        }

        return output
    }

    private static func replacePairs(in text: String, marker: String, tag: String) -> String {
        var result = ""
        var remaining = text[...]
        var isOpen = false

        while let range = remaining.range(of: marker) {
            result += remaining[..<range.lowerBound]
            result += isOpen ? "</\(tag)>" : "<\(tag)>"
            remaining = remaining[range.upperBound...]
            isOpen.toggle()
        }

        result += remaining
        if isOpen {
            result += "</\(tag)>"
        }
        return result
    }

    private static func escapeHTML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}

final class CompanionHTTPServer {
    private let port: UInt16
    private let handler: (CompanionHTTPRequest) async -> CompanionHTTPResponse
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "MiWhisper.CompanionHTTPServer")
    private var activeConnections: [UUID: CompanionHTTPConnection] = [:]
    private var stopping = false
    var onFailure: ((String) -> Void)?

    init(
        port: UInt16,
        handler: @escaping (CompanionHTTPRequest) async -> CompanionHTTPResponse
    ) throws {
        self.port = port
        self.handler = handler
    }

    func start() throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let endpointPort = NWEndpoint.Port(rawValue: port)!
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: endpointPort)
        let listener = try NWListener(using: parameters)
        stopping = false
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed(let error):
                self?.onFailure?("listener failed: \(error.localizedDescription)")
            case .cancelled:
                guard self?.stopping == false else { return }
                self?.onFailure?("listener cancelled unexpectedly")
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            let identifier = UUID()
            let session = CompanionHTTPConnection(
                id: identifier,
                connection: connection,
                handler: self.handler,
                onClose: { [weak self] id in
                    self?.queue.async {
                        self?.activeConnections.removeValue(forKey: id)
                    }
                }
            )
            self.activeConnections[identifier] = session
            session.start()
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        stopping = true
        activeConnections.removeAll()
        listener?.cancel()
        listener = nil
    }
}

private final class CompanionHTTPConnection {
    private let id: UUID
    private let connection: NWConnection
    private let handler: (CompanionHTTPRequest) async -> CompanionHTTPResponse
    private let onClose: (UUID) -> Void
    private let queue: DispatchQueue
    private var buffer = Data()
    private var hasStartedReceiving = false
    private var isClosed = false
    fileprivate var streamWriter: CompanionResponseStreamWriter?

    init(
        id: UUID,
        connection: NWConnection,
        handler: @escaping (CompanionHTTPRequest) async -> CompanionHTTPResponse,
        onClose: @escaping (UUID) -> Void
    ) {
        self.id = id
        self.connection = connection
        self.handler = handler
        self.onClose = onClose
        self.queue = DispatchQueue(label: "MiWhisper.CompanionHTTPConnection.\(id.uuidString)")
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }

            switch state {
            case .ready:
                guard !self.hasStartedReceiving else { return }
                self.hasStartedReceiving = true
                self.receive()
            case .failed, .cancelled:
                self.close()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let data, !data.isEmpty {
                self.buffer.append(data)
            }

            switch CompanionHTTPRequest.parse(from: self.buffer) {
            case .success(let request):
                Task {
                    let response = await self.handler(request)
                    self.send(response)
                }

            case .failure(let response):
                self.send(response)

            case .incomplete:
                if isComplete || error != nil {
                    self.close()
                    return
                }
                self.receive()
            }
        }
    }

    private func send(_ response: CompanionHTTPResponse) {
        if let streamHandler = response.streamHandler {
            let headersData = response.serializedData
            connection.send(content: headersData, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                if error != nil {
                    self.close()
                    return
                }
                let writer = CompanionResponseStreamWriter(connection: self.connection)
                self.streamWriter = writer
                Task {
                    await streamHandler(writer)
                    writer.close()
                    self.close()
                }
            })
        } else {
            connection.send(content: response.serializedData, completion: .contentProcessed { [weak self] _ in
                self?.close()
            })
        }
    }

    fileprivate func close() {
        guard !isClosed else { return }
        isClosed = true
        streamWriter?.close()
        streamWriter = nil
        connection.cancel()
        onClose(id)
    }
}

final class CompanionResponseStreamWriter: @unchecked Sendable {
    private let connection: NWConnection
    private let lock = NSLock()
    private var isClosed: Bool = false

    fileprivate init(connection: NWConnection) {
        self.connection = connection
    }

    var closed: Bool {
        lock.lock(); defer { lock.unlock() }
        return isClosed
    }

    func close() {
        lock.lock()
        let wasOpen = !isClosed
        isClosed = true
        lock.unlock()
        if wasOpen {
            // intentionally do not cancel the underlying connection here — the owning
            // CompanionHTTPConnection is responsible for lifecycle.
        }
    }

    func send(event: String? = nil, data: String) {
        guard !closed else { return }
        var payload = ""
        if let event {
            payload.append("event: \(event)\n")
        }
        let lines = data.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.isEmpty {
            payload.append("data: \n")
        } else {
            for line in lines {
                payload.append("data: \(String(line))\n")
            }
        }
        payload.append("\n")
        write(Data(payload.utf8))
    }

    func keepAlive() {
        guard !closed else { return }
        write(Data(": keepalive\n\n".utf8))
    }

    private func write(_ data: Data) {
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if error != nil {
                self?.close()
            }
        })
    }
}

enum CompanionHTTPRequestParseResult {
    case incomplete
    case success(CompanionHTTPRequest)
    case failure(CompanionHTTPResponse)
}

struct CompanionHTTPRequest {
    let method: String
    let target: String
    let path: String
    let queryItems: [URLQueryItem]
    let headers: [String: String]
    let body: Data

    var jsonObject: Any? {
        guard !body.isEmpty else { return nil }
        return try? JSONSerialization.jsonObject(with: body)
    }

    func queryValue(named name: String) -> String? {
        queryItems.first(where: { $0.name == name })?.value
    }

    func headerValue(named name: String) -> String? {
        headers[name.lowercased()]
    }

    static func parse(from data: Data) -> CompanionHTTPRequestParseResult {
        guard let headerRange = data.range(of: Data("\r\n\r\n".utf8)) else {
            return .incomplete
        }

        let headerData = data.subdata(in: 0..<headerRange.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            return .failure(.json(["error": "Malformed request headers"], status: 400))
        }

        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            return .failure(.json(["error": "Missing request line"], status: 400))
        }

        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else {
            return .failure(.json(["error": "Malformed request line"], status: 400))
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let name = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[name] = value
        }

        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = headerRange.upperBound
        let totalLength = bodyStart + contentLength

        guard data.count >= totalLength else {
            return .incomplete
        }

        let body = data.subdata(in: bodyStart..<totalLength)
        let target = String(parts[1])
        let components = URLComponents(string: "http://localhost\(target)")

        return .success(
            CompanionHTTPRequest(
                method: String(parts[0]).uppercased(),
                target: target,
                path: components?.path ?? target,
                queryItems: components?.queryItems ?? [],
                headers: headers,
                body: body
            )
        )
    }
}

struct CompanionHTTPResponse {
    let status: Int
    let contentType: String
    let headers: [String: String]
    let body: Data
    let streamHandler: (@Sendable (CompanionResponseStreamWriter) async -> Void)?

    init(
        status: Int,
        contentType: String,
        headers: [String: String],
        body: Data,
        streamHandler: (@Sendable (CompanionResponseStreamWriter) async -> Void)? = nil
    ) {
        self.status = status
        self.contentType = contentType
        self.headers = headers
        self.body = body
        self.streamHandler = streamHandler
    }

    var isStreaming: Bool { streamHandler != nil }

    var serializedData: Data {
        var lines = ["HTTP/1.1 \(status) \(reasonPhrase(for: status))"]
        lines.append("Content-Type: \(contentType)")
        if streamHandler == nil {
            lines.append("Content-Length: \(body.count)")
            lines.append("Connection: close")
        } else {
            lines.append("Connection: keep-alive")
            lines.append("Cache-Control: no-store, no-transform")
            lines.append("X-Accel-Buffering: no")
        }

        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            lines.append("\(name): \(value)")
        }

        lines.append("")
        lines.append("")

        var data = Data(lines.joined(separator: "\r\n").utf8)
        if streamHandler == nil {
            data.append(body)
        }
        return data
    }

    static func eventStream(
        handler: @escaping @Sendable (CompanionResponseStreamWriter) async -> Void
    ) -> CompanionHTTPResponse {
        CompanionHTTPResponse(
            status: 200,
            contentType: "text/event-stream; charset=utf-8",
            headers: [:],
            body: Data(),
            streamHandler: handler
        )
    }

    static func json(
        _ value: Any,
        status: Int = 200,
        cacheControl: String = "no-store"
    ) -> CompanionHTTPResponse {
        let data: Data

        if let encodableValue = value as? EncodableBox {
            data = (try? encodableValue.encode()) ?? Data("{}".utf8)
        } else if let object = value as? [String: Any], JSONSerialization.isValidJSONObject(object) {
            data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted])) ?? Data("{}".utf8)
        } else {
            data = Data("{}".utf8)
        }

        return CompanionHTTPResponse(
            status: status,
            contentType: "application/json; charset=utf-8",
            headers: [
                "Cache-Control": cacheControl,
                "Access-Control-Allow-Origin": "self",
            ],
            body: data
        )
    }

    static func json<T: Encodable>(
        _ value: T,
        status: Int = 200,
        cacheControl: String = "no-store"
    ) -> CompanionHTTPResponse {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = (try? encoder.encode(value)) ?? Data("{}".utf8)

        return CompanionHTTPResponse(
            status: status,
            contentType: "application/json; charset=utf-8",
            headers: [
                "Cache-Control": cacheControl,
            ],
            body: data
        )
    }

    static func html(_ html: String, cacheControl: String = "no-store") -> CompanionHTTPResponse {
        CompanionHTTPResponse(
            status: 200,
            contentType: "text/html; charset=utf-8",
            headers: ["Cache-Control": cacheControl],
            body: Data(html.utf8)
        )
    }

    static func javascript(_ source: String, cacheControl: String = "public, max-age=60") -> CompanionHTTPResponse {
        CompanionHTTPResponse(
            status: 200,
            contentType: "application/javascript; charset=utf-8",
            headers: ["Cache-Control": cacheControl],
            body: Data(source.utf8)
        )
    }

    static func css(_ source: String, cacheControl: String = "public, max-age=60") -> CompanionHTTPResponse {
        CompanionHTTPResponse(
            status: 200,
            contentType: "text/css; charset=utf-8",
            headers: ["Cache-Control": cacheControl],
            body: Data(source.utf8)
        )
    }

    static func svg(_ source: String, cacheControl: String = "public, max-age=86400") -> CompanionHTTPResponse {
        CompanionHTTPResponse(
            status: 200,
            contentType: "image/svg+xml; charset=utf-8",
            headers: ["Cache-Control": cacheControl],
            body: Data(source.utf8)
        )
    }

    static func redirect(location: String) -> CompanionHTTPResponse {
        CompanionHTTPResponse(
            status: 302,
            contentType: "text/plain; charset=utf-8",
            headers: [
                "Location": location,
                "Cache-Control": "no-store",
            ],
            body: Data("Redirecting…".utf8)
        )
    }

    static func binary(
        _ data: Data,
        status: Int,
        contentType: String,
        cacheControl: String = "no-store",
        headers extraHeaders: [String: String] = [:]
    ) -> CompanionHTTPResponse {
        var headers = extraHeaders
        headers["Cache-Control"] = cacheControl
        return CompanionHTTPResponse(
            status: status,
            contentType: contentType,
            headers: headers,
            body: data
        )
    }

    private func reasonPhrase(for status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 201: return "Created"
        case 302: return "Found"
        case 400: return "Bad Request"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 415: return "Unsupported Media Type"
        case 500: return "Internal Server Error"
        case 503: return "Service Unavailable"
        default: return "HTTP Response"
        }
    }
}

private protocol EncodableBox {
    func encode() throws -> Data
}

extension CompanionBootstrapPayload: EncodableBox {
    fileprivate func encode() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
}

extension Array: EncodableBox where Element: Encodable {
    fileprivate func encode() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
}

extension CompanionSessionDetail: EncodableBox {
    fileprivate func encode() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
}

enum CompanionPWA {
    static let version = "v55"

    static func manifest(port: Int) -> [String: Any] {
        [
            "name": "MiWhisper Chat",
            "short_name": "MiWhisper",
            "display": "standalone",
            "display_override": ["standalone", "minimal-ui"],
            "orientation": "portrait-primary",
            "start_url": "/",
            "scope": "/",
            "background_color": "#f7f7f5",
            "theme_color": "#f7f7f5",
            "description": "Codex-style companion bridge for MiWhisper running on your Mac.",
            "lang": "es",
            "icons": [
                [
                    "src": "/icon.svg",
                    "sizes": "any",
                    "type": "image/svg+xml",
                    "purpose": "any",
                ],
                [
                    "src": "/icon-maskable.svg",
                    "sizes": "any",
                    "type": "image/svg+xml",
                    "purpose": "maskable",
                ],
                [
                    "src": "/app-icon.png",
                    "sizes": "256x256",
                    "type": "image/png",
                    "purpose": "any",
                ],
                [
                    "src": "/apple-touch-icon.png",
                    "sizes": "180x180",
                    "type": "image/png",
                    "purpose": "any",
                ],
            ],
            "shortcuts": [
                [
                    "name": "Nueva sesión",
                    "short_name": "Nueva",
                    "url": "/?action=new",
                ],
            ],
        ]
    }

    static let iconSVG = #"""
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512" role="img" aria-label="MiWhisper">
      <defs>
        <linearGradient id="mwBg" x1="0" y1="0" x2="1" y2="1">
          <stop offset="0" stop-color="#2f2f2f"/>
          <stop offset="1" stop-color="#0d0d0d"/>
        </linearGradient>
        <linearGradient id="mwHi" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stop-color="#ffffff" stop-opacity="0.35"/>
          <stop offset="1" stop-color="#ffffff" stop-opacity="0"/>
        </linearGradient>
      </defs>
      <rect width="512" height="512" rx="112" fill="url(#mwBg)"/>
      <rect width="512" height="256" rx="112" fill="url(#mwHi)"/>
      <g fill="#ffffff">
        <path d="M112 360V152h44l52 124 52-124h44v208h-36V226l-48 110h-24l-48-110v134z"/>
        <rect x="336" y="176" width="32" height="184" rx="6"/>
        <circle cx="352" cy="148" r="20"/>
      </g>
    </svg>
    """#

    static let iconMaskableSVG = #"""
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512" role="img" aria-label="MiWhisper">
      <defs>
        <linearGradient id="mmBg" x1="0" y1="0" x2="1" y2="1">
          <stop offset="0" stop-color="#2f2f2f"/>
          <stop offset="1" stop-color="#0d0d0d"/>
        </linearGradient>
      </defs>
      <rect width="512" height="512" fill="url(#mmBg)"/>
      <g fill="#ffffff" transform="translate(96 96) scale(0.625)">
        <path d="M112 360V152h44l52 124 52-124h44v208h-36V226l-48 110h-24l-48-110v134z"/>
        <rect x="336" y="176" width="32" height="184" rx="6"/>
        <circle cx="352" cy="148" r="20"/>
      </g>
    </svg>
    """#

    private static let appleTouchIconCache = AppleTouchIconCache()

    static func appleTouchIconPNG() -> Data {
        appleTouchIconCache.data
    }

    static func appIconPNG(size: Int) -> Data {
        AppleTouchIconCache.renderAppIcon(size: size)
    }

    static let indexHTML = #"""
    <!doctype html>
    <html lang="es" data-theme="light">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover, interactive-widget=resizes-content">
      <meta name="theme-color" content="#f7f7f5" media="(prefers-color-scheme: light)">
      <meta name="theme-color" content="#0f0f0f" media="(prefers-color-scheme: dark)">
      <meta name="apple-mobile-web-app-capable" content="yes">
      <meta name="apple-mobile-web-app-status-bar-style" content="default">
      <meta name="apple-mobile-web-app-title" content="MiWhisper">
      <meta name="color-scheme" content="light dark">
      <title>MiWhisper Codex</title>
      <link rel="manifest" href="/manifest.webmanifest">
      <link rel="icon" type="image/svg+xml" href="/icon.svg">
      <link rel="apple-touch-icon" href="/apple-touch-icon.png">
      <link rel="stylesheet" href="/app.css">
    </head>
    <body>
      <div id="connection-banner" class="connection-banner" data-state="ok" role="status" aria-live="polite" hidden>
        <span class="banner-dot" aria-hidden="true"></span>
        <span class="banner-text" id="connection-banner-text">Conectado</span>
        <button class="banner-action" id="connection-banner-retry" type="button" hidden>Reintentar</button>
      </div>

      <div id="app">
        <aside class="drawer" id="drawer" data-open="false" aria-hidden="true">
          <div class="drawer-backdrop" data-close-drawer></div>
          <div class="drawer-panel" role="navigation" aria-label="Sesiones y workspaces">
            <header class="drawer-header">
              <div class="brand">
                <img class="brand-mark" src="/app-icon.png" alt="" aria-hidden="true">
                <div class="brand-text">
                  <span class="brand-title">MiWhisper</span>
                  <span class="brand-subtitle">local Codex bridge</span>
                </div>
              </div>
              <button class="icon-button drawer-close" data-close-drawer aria-label="Cerrar menú" type="button">
                <svg viewBox="0 0 24 24" width="20" height="20" aria-hidden="true"><path fill="currentColor" d="M18.3 5.71 12 12l6.3 6.29-1.41 1.42L10.58 13.4l-6.3 6.3L2.86 18.3 9.17 12 2.86 5.71 4.28 4.29l6.3 6.29 6.31-6.29z"/></svg>
              </button>
            </header>

            <button id="new-session-button" class="primary-button drawer-new-chat" type="button">
              <svg viewBox="0 0 24 24" width="18" height="18" aria-hidden="true"><path fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" d="M12 5v14M5 12h14"/></svg>
              Nuevo chat
              <kbd class="kbd-hint">⌘⇧N</kbd>
            </button>

            <section class="drawer-section drawer-workspace-section">
              <p class="drawer-label">Workspace</p>
              <div id="workspace-chips" class="workspace-chips"></div>
            </section>

            <section class="drawer-section drawer-section-grow">
              <header class="drawer-section-head">
                <p class="drawer-label">Conversaciones</p>
                <div class="drawer-section-head-actions">
                  <button id="command-palette-button" class="ghost-icon" aria-label="Paleta de comandos" title="Paleta de comandos (⌘K)" type="button">
                    <svg viewBox="0 0 24 24" width="16" height="16" aria-hidden="true"><path fill="currentColor" d="M15.5 14h-.79l-.28-.27a6.5 6.5 0 1 0-.7.7l.27.28v.79l5 4.99L20.49 19zM9.5 14a4.5 4.5 0 1 1 0-9 4.5 4.5 0 0 1 0 9"/></svg>
                  </button>
                  <button id="refresh-button" class="ghost-icon" aria-label="Refrescar" title="Refrescar" type="button">
                    <svg viewBox="0 0 24 24" width="16" height="16" aria-hidden="true"><path fill="currentColor" d="M17.65 6.35A7.96 7.96 0 0 0 12 4a8 8 0 1 0 7.75 10h-2.08A6 6 0 1 1 12 6c1.66 0 3.14.69 4.22 1.78L13 11h7V4z"/></svg>
                  </button>
                </div>
              </header>
              <div id="session-list" class="session-list" role="list"></div>
            </section>

            <footer class="drawer-footer">
              <button id="theme-toggle" class="ghost-icon theme-toggle" type="button" aria-label="Cambiar tema" title="Cambiar tema">
                <svg class="theme-icon theme-icon-sun" viewBox="0 0 24 24" width="16" height="16" aria-hidden="true"><path fill="currentColor" d="M12 4V2m0 20v-2m8-8h2M2 12h2m13.66-5.66 1.41-1.41M4.93 19.07l1.41-1.41m0-11.32L4.93 4.93m14.14 14.14-1.41-1.41M12 7a5 5 0 1 0 .001 10.001A5 5 0 0 0 12 7"/></svg>
                <svg class="theme-icon theme-icon-moon" viewBox="0 0 24 24" width="16" height="16" aria-hidden="true"><path fill="currentColor" d="M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79"/></svg>
              </button>
              <span class="footer-dot" id="footer-dot" aria-hidden="true"></span>
              <span class="footer-text">Local bridge · <span id="app-version">v31</span> · <span id="bridge-status">conectado</span></span>
              <button id="install-button" class="ghost-icon install-button" type="button" aria-label="Instalar app" title="Instalar app" hidden>
                <svg viewBox="0 0 24 24" width="16" height="16" aria-hidden="true"><path fill="currentColor" d="M5 20h14v-2H5zM12 4l-5 5h3v6h4V9h3z"/></svg>
              </button>
            </footer>
          </div>
        </aside>

        <main class="stage" id="stage">
          <header class="topbar">
            <button class="icon-button" id="menu-button" aria-label="Abrir menú" type="button">
              <svg viewBox="0 0 24 24" width="22" height="22" aria-hidden="true"><path fill="currentColor" d="M3 6h18v2H3zm0 5h18v2H3zm0 5h18v2H3z"/></svg>
            </button>
            <div class="topbar-title">
              <h1 id="session-title" title="">Nuevo chat</h1>
              <p id="session-subtitle" class="topbar-subtitle"></p>
            </div>
            <div class="topbar-actions">
              <button id="car-mode-toggle" class="icon-button car-mode-toggle" type="button" aria-label="Modo coche" title="Modo coche">
                <svg viewBox="0 0 24 24" width="20" height="20" aria-hidden="true"><path fill="currentColor" d="M5.7 8.8 7 5.6A3 3 0 0 1 9.78 3.7h4.44A3 3 0 0 1 17 5.6l1.3 3.2A3 3 0 0 1 21 11.78V17a2 2 0 0 1-2 2h-1.1a2.4 2.4 0 0 1-4.55 0h-2.7a2.4 2.4 0 0 1-4.55 0H5a2 2 0 0 1-2-2v-5.22A3 3 0 0 1 5.7 8.8M8.86 6.35 7.9 8.7h8.2l-.96-2.35a1 1 0 0 0-.93-.65H9.79a1 1 0 0 0-.93.65M6.6 16.6a.9.9 0 1 0 0 1.8.9.9 0 0 0 0-1.8m10.8 0a.9.9 0 1 0 0 1.8.9.9 0 0 0 0-1.8M5 11.78V17h1.1a2.4 2.4 0 0 1 4.55 0h2.7a2.4 2.4 0 0 1 4.55 0H19v-5.22a1 1 0 0 0-1-1H6a1 1 0 0 0-1 1"/></svg>
              </button>
              <button id="session-menu-button" class="icon-button" hidden type="button" aria-label="Acciones de sesión" title="Acciones de sesión">
                <svg viewBox="0 0 24 24" width="20" height="20" aria-hidden="true"><path fill="currentColor" d="M12 8a2 2 0 1 0 0-4 2 2 0 0 0 0 4m0 6a2 2 0 1 0 0-4 2 2 0 0 0 0 4m0 6a2 2 0 1 0 0-4 2 2 0 0 0 0 4"/></svg>
              </button>
              <button id="focus-button" class="icon-button" hidden type="button" aria-label="Abrir en el Mac" title="Abrir en el Mac">
                <svg viewBox="0 0 24 24" width="20" height="20" aria-hidden="true"><path fill="currentColor" d="M14 3h7v7h-2V6.41l-8.29 8.3-1.42-1.42 8.3-8.29H14zM5 5h6v2H7v10h10v-4h2v6H5z"/></svg>
              </button>
              <button id="stop-button" class="icon-button stop" hidden type="button" aria-label="Detener">
                <svg viewBox="0 0 24 24" width="18" height="18" aria-hidden="true"><rect x="6" y="6" width="12" height="12" rx="2" fill="currentColor"/></svg>
              </button>
            </div>
          </header>

          <section id="live-strip" class="live-strip" data-state="idle" hidden aria-live="polite"></section>

          <section id="car-mode-panel" class="car-mode-panel" hidden aria-live="polite">
            <div class="car-mode-shell" id="car-mode-shell" data-state="idle">
              <div class="car-status-row">
                <span class="car-status-glyph" id="car-status-glyph" data-state="idle" aria-hidden="true">•</span>
                <div class="car-status-copy">
                  <span class="car-status-label" id="car-status-label">Terminado</span>
                  <span class="car-status-detail" id="car-status-detail">Toca el micro para dictar un prompt.</span>
                </div>
              </div>
              <div class="car-main">
                <h2 id="car-mode-title">Modo coche</h2>
                <p id="car-mode-summary">Interfaz limpia: dicta, escucha un resumen y deja los detalles para cuando pares.</p>
              </div>
              <div class="car-mode-actions" role="group" aria-label="Controles de modo coche">
                <button id="car-voice-button" class="car-action car-action-primary" type="button">
                  <svg viewBox="0 0 24 24" width="30" height="30" aria-hidden="true"><path fill="currentColor" d="M12 14a3 3 0 0 0 3-3V6a3 3 0 0 0-6 0v5a3 3 0 0 0 3 3zm5-3a5 5 0 0 1-10 0H5a7 7 0 0 0 6 6.92V21h2v-3.08A7 7 0 0 0 19 11z"/></svg>
                  <span id="car-voice-label">Hablar</span>
                </button>
                <button id="car-arm-button" class="car-action" type="button">
                  <svg viewBox="0 0 24 24" width="24" height="24" aria-hidden="true"><path fill="currentColor" d="M12 3a9 9 0 0 0-9 9h2a7 7 0 1 1 2.05 4.95l-1.41 1.41A9 9 0 1 0 12 3zm0 4a5 5 0 0 0-5 5h2a3 3 0 1 1 3 3v2a5 5 0 0 0 0-10zm-1 4v2h2v-2z"/></svg>
                  <span id="car-arm-label">Armar</span>
                </button>
                <button id="car-repeat-button" class="car-action" type="button">
                  <svg viewBox="0 0 24 24" width="24" height="24" aria-hidden="true"><path fill="currentColor" d="M7 7h10v3l4-4-4-4v3H5v6h2zm10 10H7v-3l-4 4 4 4v-3h12v-6h-2z"/></svg>
                  <span>Repetir</span>
                </button>
                <button id="car-stop-audio-button" class="car-action" type="button">
                  <svg viewBox="0 0 24 24" width="24" height="24" aria-hidden="true"><path fill="currentColor" d="M7 7h10v10H7z"/></svg>
                  <span>Parar</span>
                </button>
              </div>
              <div class="car-verbosity" role="group" aria-label="Detalle del resumen">
                <button type="button" data-car-verbosity="brief">Breve</button>
                <button type="button" data-car-verbosity="normal">Normal</button>
                <button type="button" data-car-verbosity="detail">Detalle</button>
              </div>
            </div>
          </section>

          <section id="chat-stream" class="chat-stream" tabindex="-1" aria-live="polite" aria-busy="false"></section>

          <button id="scroll-bottom" class="scroll-bottom" hidden type="button" aria-label="Ir al final">
            <svg viewBox="0 0 24 24" width="18" height="18" aria-hidden="true"><path fill="currentColor" d="M12 16.5 5 9.5l1.41-1.41L12 13.67l5.59-5.58L19 9.5z"/></svg>
            <span id="scroll-bottom-badge" class="scroll-bottom-badge" hidden></span>
          </button>

          <footer class="composer-dock" id="composer-dock">
            <div class="suggestion-popup" id="suggestion-popup" hidden role="listbox" aria-label="Sugerencias">
              <div class="suggestion-header" id="suggestion-header"></div>
              <div class="suggestion-list" id="suggestion-list"></div>
            </div>
            <div class="voice-overlay" id="voice-overlay" hidden aria-hidden="true">
              <div class="voice-overlay-panel">
                <canvas id="voice-canvas" width="420" height="80" aria-hidden="true"></canvas>
                <div class="voice-overlay-meta">
                  <span class="voice-timer" id="voice-timer">0:00</span>
                  <span class="voice-hint" id="voice-hint">Suelta para enviar · Desliza izquierda para cancelar</span>
                </div>
              </div>
            </div>
            <div class="voice-processing" id="voice-processing" hidden role="status" aria-live="polite">
              <span class="voice-processing-spinner" aria-hidden="true"></span>
              <span id="voice-processing-text">Subiendo audio...</span>
            </div>
            <div class="runtime-bar" id="runtime-bar" role="group" aria-label="Controles de Codex">
              <button class="runtime-pill" id="plan-mode-toggle" type="button" aria-pressed="false" title="Plan antes de ejecutar">Plan</button>
              <label class="runtime-select-label" title="Latencia/coste para el siguiente turno">
                <span>Speed</span>
                <select class="runtime-select" id="service-tier-select" aria-label="Speed">
                  <option value="useConfigDefault">Default</option>
                  <option value="fast">Fast</option>
                  <option value="flex">Flex</option>
                </select>
              </label>
              <label class="runtime-select-label" title="Reasoning para el siguiente turno">
                <span>Think</span>
                <select class="runtime-select" id="reasoning-select" aria-label="Reasoning">
                  <option value="useConfigDefault">Default</option>
                  <option value="low">Low</option>
                  <option value="medium">Medium</option>
                  <option value="high">High</option>
                  <option value="intense">Extreme</option>
                </select>
              </label>
              <button class="runtime-pill runtime-busy-mode" id="queue-mode-toggle" type="button" aria-pressed="false" title="Cambiar entre intervenir ahora o encolar" hidden>Intervenir</button>
              <button class="runtime-access" id="access-mode-toggle" type="button" aria-pressed="false" title="Cambiar Full Access / On-Request para el siguiente turno">Full access</button>
              <button class="runtime-icon-pill" id="notifications-toggle" type="button" aria-pressed="false" title="Avisos al terminar">
                <svg viewBox="0 0 24 24" width="15" height="15" aria-hidden="true"><path fill="currentColor" d="M12 22a2.5 2.5 0 0 0 2.45-2h-4.9A2.5 2.5 0 0 0 12 22m7-6v-5a7 7 0 1 0-14 0v5l-2 2v1h18v-1z"/></svg>
              </button>
              <span class="composer-status" id="composer-status"></span>
            </div>
            <div class="composer-queue" id="composer-queue" hidden></div>
            <div class="attachment-tray" id="attachment-tray" hidden></div>
            <div class="composer" id="composer-shell">
              <input id="image-input" type="file" accept="image/*" multiple hidden>
              <button class="attachment-button" id="attachment-button" type="button" aria-label="Adjuntar foto" title="Adjuntar foto o imagen">
                <svg viewBox="0 0 24 24" width="21" height="21" aria-hidden="true"><path fill="currentColor" d="M19 5h-2.18l-1.7-2H8.88l-1.7 2H5a3 3 0 0 0-3 3v9a3 3 0 0 0 3 3h14a3 3 0 0 0 3-3V8a3 3 0 0 0-3-3m-7 12a4.5 4.5 0 1 1 0-9 4.5 4.5 0 0 1 0 9m0-2a2.5 2.5 0 1 0 0-5 2.5 2.5 0 0 0 0 5"/></svg>
              </button>
              <button class="mic-button" id="voice-button" type="button" aria-label="Grabar voz" title="Mantén pulsado para grabar">
                <svg class="mic-icon" viewBox="0 0 24 24" width="22" height="22" aria-hidden="true"><path fill="currentColor" d="M12 14a3 3 0 0 0 3-3V6a3 3 0 0 0-6 0v5a3 3 0 0 0 3 3zm5-3a5 5 0 0 1-10 0H5a7 7 0 0 0 6 6.92V21h2v-3.08A7 7 0 0 0 19 11z"/></svg>
                <span class="mic-timer" id="mic-timer" hidden>0:00</span>
              </button>
              <textarea id="composer" rows="1" placeholder="Pregunta o dicta..." autocomplete="off" autocorrect="on" spellcheck="true" enterkeyhint="send"></textarea>
              <button class="send-button" id="send-button" type="button" aria-label="Enviar">
                <svg viewBox="0 0 24 24" width="20" height="20" aria-hidden="true"><path fill="currentColor" d="m3.4 20.4 17.45-7.48a1 1 0 0 0 0-1.84L3.4 3.6a1 1 0 0 0-1.38 1.17L4.2 11 12 12l-7.8 1-2.18 6.23a1 1 0 0 0 1.38 1.17z"/></svg>
              </button>
            </div>
            <p class="composer-hint" id="composer-hint">Enter envia · Shift Enter salto · / comandos · @ archivos · voz local · fotos</p>
          </footer>
        </main>
      </div>

      <div class="palette" id="command-palette" hidden role="dialog" aria-modal="true" aria-label="Paleta de comandos">
        <div class="palette-backdrop" data-close-palette></div>
        <div class="palette-panel" role="document">
          <div class="palette-search">
            <svg viewBox="0 0 24 24" width="18" height="18" aria-hidden="true"><path fill="currentColor" d="M15.5 14h-.79l-.28-.27a6.5 6.5 0 1 0-.7.7l.27.28v.79l5 4.99L20.49 19zM9.5 14a4.5 4.5 0 1 1 0-9 4.5 4.5 0 0 1 0 9"/></svg>
            <input id="palette-input" type="text" placeholder="Buscar acción o sesión…" autocomplete="off" spellcheck="false">
            <kbd class="kbd-hint">Esc</kbd>
          </div>
          <div id="palette-results" class="palette-results" role="listbox"></div>
          <div class="palette-footer">
            <span><kbd>↑</kbd><kbd>↓</kbd> navegar</span>
            <span><kbd>↵</kbd> ejecutar</span>
          </div>
        </div>
      </div>

      <div class="toast-stack" id="toast-stack" aria-live="polite" aria-atomic="false"></div>

      <template id="skeleton-template">
        <div class="skeleton-wrap">
          <div class="skeleton skeleton-line" style="width: 38%"></div>
          <div class="skeleton skeleton-line" style="width: 78%"></div>
          <div class="skeleton skeleton-line" style="width: 64%"></div>
        </div>
      </template>

      <script src="/app.js" type="module"></script>
    </body>
    </html>
    """#

    static let appCSS = #"""
    :root {
      color-scheme: light;
      --canvas: oklch(97.5% 0.006 92);
      --canvas-strong: oklch(93.6% 0.007 92);
      --surface: oklch(99.1% 0.004 92);
      --surface-muted: oklch(95.2% 0.006 92);
      --surface-sunk: oklch(91.8% 0.008 92);
      --surface-hover: oklch(96.6% 0.006 92);
      --border: oklch(26% 0.012 92 / 0.10);
      --border-strong: oklch(26% 0.012 92 / 0.18);
      --text: oklch(19% 0.012 92);
      --text-soft: oklch(31% 0.012 92);
      --text-muted: oklch(48% 0.011 92);
      --text-faint: oklch(66% 0.010 92);
      --accent: oklch(48% 0.115 248);
      --accent-strong: oklch(36% 0.12 248);
      --accent-soft: oklch(64% 0.09 248 / 0.12);
      --accent-tint: oklch(64% 0.09 248 / 0.18);
      --danger: oklch(50% 0.14 28);
      --danger-soft: oklch(62% 0.12 28 / 0.12);
      --warning: oklch(54% 0.105 72);
      --success: oklch(49% 0.11 142);
      --user-bubble-bg: oklch(91.5% 0.018 248);
      --user-bubble-fg: oklch(19% 0.018 248);
      --on-solid: oklch(98% 0.006 92);
      --shadow-sm: 0 1px 1px oklch(19% 0.012 92 / 0.04);
      --shadow-md: 0 8px 24px oklch(19% 0.012 92 / 0.08);
      --shadow-lg: 0 18px 44px oklch(19% 0.012 92 / 0.13);
      --shadow-palette: 0 22px 72px oklch(19% 0.012 92 / 0.18);
      --radius-sm: 6px;
      --radius-md: 8px;
      --radius-lg: 10px;
      --radius-xl: 12px;
      --radius-pill: 999px;
      --sans: "SF Pro Text", -apple-system, BlinkMacSystemFont, "Inter", "Segoe UI", system-ui, sans-serif;
      --display: "SF Pro Display", "SF Pro Text", -apple-system, BlinkMacSystemFont, "Inter", "Segoe UI", system-ui, sans-serif;
      --mono: ui-monospace, SFMono-Regular, "SF Mono", "JetBrains Mono", Menlo, monospace;
      --focus: 0 0 0 3px oklch(48% 0.115 248 / 0.20);
      --code-bg: oklch(20% 0.018 248);
      --code-fg: oklch(95% 0.006 92);
      --diff-add-bg: rgba(22, 163, 74, 0.12);
      --diff-add-fg: #15803d;
      --diff-del-bg: rgba(220, 38, 38, 0.10);
      --diff-del-fg: #b91c1c;
      --diff-hunk-bg: oklch(26% 0.012 92 / 0.06);
      --diff-hunk-fg: #4a4a46;
      --syntax-keyword: #c084fc;
      --syntax-string: #86efac;
      --syntax-number: #fbbf24;
      --syntax-comment: #94a3b8;
      --syntax-func: #60a5fa;
      --syntax-type: #f472b6;
    }

    :root[data-theme="dark"] {
      color-scheme: dark;
      --canvas: oklch(18% 0.010 92);
      --canvas-strong: oklch(14% 0.010 92);
      --surface: oklch(22% 0.012 92);
      --surface-muted: oklch(19.5% 0.012 92);
      --surface-sunk: oklch(27% 0.012 92);
      --surface-hover: oklch(25% 0.012 92);
      --border: oklch(91% 0.007 92 / 0.08);
      --border-strong: oklch(91% 0.007 92 / 0.16);
      --text: oklch(94% 0.006 92);
      --text-soft: oklch(84% 0.007 92);
      --text-muted: oklch(68% 0.008 92);
      --text-faint: oklch(50% 0.009 92);
      --accent: oklch(70% 0.11 248);
      --accent-strong: oklch(82% 0.085 248);
      --accent-soft: oklch(70% 0.11 248 / 0.12);
      --accent-tint: oklch(70% 0.11 248 / 0.20);
      --danger: oklch(69% 0.13 28);
      --danger-soft: oklch(69% 0.13 28 / 0.15);
      --warning: oklch(73% 0.11 72);
      --success: oklch(72% 0.11 142);
      --user-bubble-bg: oklch(30% 0.026 248);
      --user-bubble-fg: oklch(94% 0.007 92);
      --on-solid: oklch(17% 0.010 92);
      --shadow-sm: 0 1px 2px oklch(9% 0.01 92 / 0.38);
      --shadow-md: 0 10px 26px oklch(9% 0.01 92 / 0.44);
      --shadow-lg: 0 22px 52px oklch(9% 0.01 92 / 0.54);
      --shadow-palette: 0 20px 72px oklch(9% 0.01 92 / 0.68);
      --code-bg: oklch(15% 0.018 248);
      --code-fg: oklch(94% 0.006 92);
      --diff-add-bg: rgba(74, 222, 128, 0.14);
      --diff-add-fg: #86efac;
      --diff-del-bg: rgba(248, 113, 113, 0.14);
      --diff-del-fg: #fca5a5;
      --diff-hunk-bg: rgba(255, 255, 255, 0.08);
      --diff-hunk-fg: #d4d4cf;
    }

    *, *::before, *::after { box-sizing: border-box; }

    [hidden] { display: none !important; }

    html, body {
      margin: 0;
      width: 100%;
      max-width: 100%;
      height: 100%;
      background: var(--canvas);
      color: var(--text);
      font-family: var(--sans);
      -webkit-font-smoothing: antialiased;
      -moz-osx-font-smoothing: grayscale;
    }

    body {
      overflow-x: hidden;
      overscroll-behavior-y: none;
      text-rendering: optimizeLegibility;
    }

    h1, h2, h3, p { margin: 0; }

    button { font: inherit; }

    :focus-visible {
      outline: none;
      box-shadow: var(--focus);
      border-radius: 10px;
    }

    ::-webkit-scrollbar { width: 10px; height: 10px; }
    ::-webkit-scrollbar-track { background: transparent; }
    ::-webkit-scrollbar-thumb {
      background: var(--border-strong);
      border-radius: 999px;
      border: 2px solid transparent;
      background-clip: padding-box;
    }
    ::-webkit-scrollbar-thumb:hover { background: var(--text-faint); background-clip: padding-box; }

    #app {
      display: grid;
      grid-template-columns: 292px minmax(0, 1fr);
      width: 100%;
      max-width: 100vw;
      height: 100dvh;
      min-height: 100dvh;
      overflow-x: hidden;
    }
    body[data-car-mode="true"] #app {
      grid-template-columns: minmax(0, 1fr);
    }
    body[data-car-mode="true"] .drawer {
      display: none;
    }

    /* ===== Connection banner ===== */
    .connection-banner {
      position: fixed;
      top: 12px;
      left: 50%;
      transform: translateX(-50%);
      z-index: 1200;
      display: inline-flex;
      align-items: center;
      gap: 8px;
      padding: 8px 12px;
      border-radius: var(--radius-pill);
      background: var(--surface);
      color: var(--text);
      box-shadow: var(--shadow-md);
      border: 1px solid var(--border);
      font-size: 0.82rem;
      font-weight: 500;
      animation: banner-in 180ms ease-out;
      max-width: calc(100vw - 24px);
    }
    .connection-banner[data-state="error"] { border-color: var(--danger); color: var(--danger); }
    .connection-banner[data-state="warn"] { border-color: var(--warning); color: var(--warning); }
    .connection-banner[data-state="ok"] { border-color: var(--success); color: var(--success); }
    .banner-dot {
      width: 8px; height: 8px; border-radius: 50%;
      background: currentColor;
      box-shadow: 0 0 0 0 currentColor;
      animation: banner-pulse 1.6s ease-in-out infinite;
    }
    .banner-action {
      background: transparent;
      border: none;
      color: currentColor;
      font-weight: 600;
      cursor: pointer;
      padding: 2px 8px;
      border-radius: 6px;
      text-decoration: underline;
      text-underline-offset: 2px;
    }
    .banner-action:hover { background: rgba(0,0,0,0.04); }
    :root[data-theme="dark"] .banner-action:hover { background: rgba(255,255,255,0.05); }

    @keyframes banner-in {
      from { opacity: 0; transform: translate(-50%, -16px); }
      to { opacity: 1; transform: translate(-50%, 0); }
    }
    @keyframes banner-pulse {
      0%, 100% { box-shadow: 0 0 0 0 currentColor; }
      50% { box-shadow: 0 0 0 6px rgba(0,0,0,0); }
    }

    /* ===== Drawer / Sidebar ===== */
    .drawer { position: relative; }
    .drawer-backdrop { display: none; }

    .drawer-panel {
      position: sticky;
      top: 0;
      height: 100dvh;
      display: grid;
      grid-template-rows: auto auto auto minmax(0, 1fr) auto;
      gap: 12px;
      padding: 12px 12px 10px;
      background: var(--surface-muted);
      border-right: 1px solid var(--border);
    }

    .drawer-header {
      display: flex;
      justify-content: space-between;
      align-items: center;
      padding: 0 2px;
    }

    .icon-button.drawer-close { display: none; }

    .brand { display: flex; align-items: center; gap: 8px; min-width: 0; }

    .brand-mark {
      width: 30px; height: 30px;
      border-radius: 8px;
      object-fit: cover;
      box-shadow: 0 1px 2px oklch(19% 0.012 92 / 0.08);
      filter: grayscale(0.88) contrast(1.04);
      flex-shrink: 0;
    }

    .brand-text { display: grid; line-height: 1.15; }
    .brand-title { font-family: var(--display); font-weight: 650; font-size: 0.92rem; }
    .brand-subtitle { font-size: 0.7rem; color: var(--text-muted); }

    .drawer-label {
      font-size: 0.64rem;
      text-transform: uppercase;
      letter-spacing: 0;
      color: var(--text-muted);
      font-weight: 600;
      padding-left: 4px;
    }

    .drawer-section { display: grid; gap: 7px; min-height: 0; }
    .drawer-workspace-section {
      overflow: hidden;
    }
    .drawer-section-grow { overflow: hidden; }

    .drawer-section-head {
      display: flex;
      align-items: center;
      justify-content: space-between;
      padding-right: 4px;
    }
    .drawer-section-head-actions { display: flex; gap: 4px; }

    .ghost-icon {
      background: transparent;
      border: none;
      color: var(--text-muted);
      width: 26px; height: 26px;
      border-radius: 7px;
      display: grid;
      place-items: center;
      cursor: pointer;
      transition: background 120ms ease, color 120ms ease, transform 120ms ease;
    }
    .ghost-icon:hover { background: var(--surface); color: var(--text); }
    .ghost-icon:active { transform: scale(0.94); }

    .primary-button {
      display: inline-flex;
      align-items: center;
      gap: 7px;
      justify-content: center;
      padding: 8px 11px;
      border-radius: 8px;
      background: var(--text);
      color: var(--canvas);
      border: 1px solid var(--text);
      font-weight: 620;
      font-size: 0.86rem;
      cursor: pointer;
      box-shadow: none;
      transition: transform 120ms ease, box-shadow 120ms ease, filter 120ms ease;
    }
    .primary-button:hover { transform: translateY(-1px); filter: brightness(1.03); }
    .primary-button:active { transform: translateY(0); }
    .drawer-new-chat { width: 100%; justify-content: flex-start; padding: 9px 11px; gap: 8px; }
    .drawer-new-chat .kbd-hint { margin-left: auto; }

    .kbd-hint, kbd {
      display: inline-flex;
      align-items: center;
      padding: 1px 6px;
      font-family: var(--mono);
      font-size: 0.7rem;
      background: rgba(255,255,255,0.12);
      color: inherit;
      border: 1px solid rgba(255,255,255,0.18);
      border-radius: 6px;
      font-weight: 500;
    }
    .primary-button .kbd-hint {
      background: color-mix(in srgb, var(--canvas) 16%, transparent);
      border-color: color-mix(in srgb, var(--canvas) 24%, transparent);
      color: var(--canvas);
    }
    .drawer-panel kbd {
      background: var(--surface);
      border-color: var(--border);
      color: var(--text-muted);
    }

    .workspace-chips {
      display: flex;
      flex-wrap: wrap;
      gap: 6px;
      max-height: clamp(96px, 22dvh, 178px);
      overflow-y: auto;
      overscroll-behavior: contain;
      align-content: flex-start;
      padding-right: 3px;
      scrollbar-gutter: stable;
    }

    .workspace-chips::-webkit-scrollbar,
    .session-list::-webkit-scrollbar {
      width: 7px;
    }
    .workspace-chips::-webkit-scrollbar-thumb,
    .session-list::-webkit-scrollbar-thumb {
      background: color-mix(in srgb, var(--text-faint) 42%, transparent);
      border-radius: 999px;
    }

    .chip {
      display: inline-flex;
      align-items: center;
      gap: 5px;
      padding: 5px 8px;
      background: var(--surface);
      border: 1px solid var(--border);
      color: var(--text-soft);
      border-radius: 8px;
      font-size: 0.75rem;
      cursor: pointer;
      transition: background 120ms ease, border 120ms ease, color 120ms ease;
    }
    .chip:hover { border-color: var(--border-strong); }
    .chip[data-active="true"] {
      background: var(--text);
      border-color: var(--text);
      color: var(--canvas);
      font-weight: 600;
    }
    .chip-dot {
      width: 6px; height: 6px; border-radius: 50%; background: currentColor; opacity: 0.7;
    }

    .session-list {
      display: grid;
      gap: 2px;
      overflow-y: auto;
      padding-right: 4px;
      padding-bottom: 6px;
      min-height: 0;
      scroll-padding-block: 12px;
    }

    .session-date-label {
      font-size: 0.62rem;
      text-transform: uppercase;
      letter-spacing: 0;
      color: var(--text-faint);
      padding: 8px 5px 2px;
      font-weight: 600;
    }

    .session-item {
      display: grid;
      grid-template-columns: minmax(0, 1fr) auto;
      align-items: center;
      gap: 6px;
      padding: 8px 8px;
      border-radius: 8px;
      cursor: pointer;
      color: var(--text-soft);
      text-align: left;
      border: 1px solid transparent;
      background: transparent;
      transition: background 120ms ease, border 120ms ease, color 120ms ease;
      min-width: 0;
    }
    .session-item:hover { background: color-mix(in srgb, var(--surface) 70%, transparent); border-color: var(--border); color: var(--text); }
    .session-item[data-active="true"] {
      background: var(--surface);
      border-color: var(--border-strong);
      color: var(--text);
      box-shadow: var(--shadow-sm);
    }

    .session-item-main {
      display: grid;
      gap: 2px;
      min-width: 0;
    }
    .session-item-title {
      font-weight: 560;
      font-size: 0.82rem;
      line-height: 1.25;
      white-space: nowrap;
      overflow: hidden;
      text-overflow: ellipsis;
      display: flex;
      align-items: center;
      gap: 6px;
    }
    .session-item-title-text {
      white-space: nowrap;
      overflow: hidden;
      text-overflow: ellipsis;
    }
    .session-item-subtitle {
      font-size: 0.7rem;
      color: var(--text-muted);
      white-space: nowrap;
      overflow: hidden;
      text-overflow: ellipsis;
      display: flex;
      align-items: center;
      gap: 6px;
      min-width: 0;
    }
    .session-item-subtitle > span:first-child {
      min-width: 0;
      overflow: hidden;
      text-overflow: ellipsis;
    }
    .session-item-meta {
      display: flex;
      align-items: center;
      gap: 6px;
      color: var(--text-faint);
    }
    .session-item-pin,
    .session-item-busy {
      width: 14px; height: 14px;
      display: grid; place-items: center;
    }
    .session-item-busy::before {
      content: "";
      width: 8px; height: 8px;
      border-radius: 50%;
      background: var(--accent);
      box-shadow: 0 0 0 0 var(--accent);
      animation: pulse-dot 1.2s ease-in-out infinite;
    }
    .session-item-pin svg { color: var(--text); }
    .session-state-light {
      width: 17px;
      height: 17px;
      border-radius: 999px;
      display: inline-grid;
      place-items: center;
      flex: 0 0 auto;
      color: var(--text-muted);
      background: var(--surface-sunk);
      border: 1px solid var(--border);
      font-size: 0.68rem;
      font-weight: 760;
      line-height: 1;
    }
    .session-state-light[data-state="thinking"],
    .session-state-light[data-state="streaming"] {
      color: var(--accent);
      border-color: color-mix(in srgb, var(--accent) 36%, var(--border));
      background: var(--accent-tint);
      animation: pulse-dot 1.35s ease-in-out infinite;
    }
    .session-state-light[data-state="command"],
    .session-state-light[data-state="tool"],
    .session-state-light[data-state="patch"],
    .session-state-light[data-state="running"] {
      color: var(--warning);
      border-color: color-mix(in srgb, var(--warning) 36%, var(--border));
      background: color-mix(in srgb, var(--warning) 10%, var(--surface));
      animation: pulse-dot 1.15s ease-in-out infinite;
    }
    .session-state-light[data-state="attention"],
    .session-state-light[data-state="error"] {
      color: var(--danger);
      border-color: color-mix(in srgb, var(--danger) 38%, var(--border));
      background: color-mix(in srgb, var(--danger) 9%, var(--surface));
    }
    .session-state-chip {
      display: inline-flex;
      align-items: center;
      flex: 0 0 auto;
      min-height: 17px;
      padding: 1px 6px;
      border-radius: var(--radius-pill);
      border: 1px solid var(--border);
      background: var(--surface-sunk);
      color: var(--text-muted);
      font-size: 0.64rem;
      font-weight: 680;
      line-height: 1.1;
    }
    .session-state-chip[data-state="thinking"],
    .session-state-chip[data-state="streaming"] {
      color: var(--accent);
      border-color: color-mix(in srgb, var(--accent) 32%, var(--border));
      background: var(--accent-tint);
    }
    .session-state-chip[data-state="command"],
    .session-state-chip[data-state="tool"],
    .session-state-chip[data-state="patch"],
    .session-state-chip[data-state="running"] {
      color: var(--warning);
      border-color: color-mix(in srgb, var(--warning) 34%, var(--border));
      background: color-mix(in srgb, var(--warning) 9%, var(--surface));
    }
    .session-state-chip[data-state="attention"],
    .session-state-chip[data-state="error"] {
      color: var(--danger);
      border-color: color-mix(in srgb, var(--danger) 34%, var(--border));
      background: color-mix(in srgb, var(--danger) 8%, var(--surface));
    }
    .session-item-kebab {
      background: transparent;
      border: none;
      color: var(--text-faint);
      width: 22px; height: 22px;
      border-radius: 6px;
      display: grid; place-items: center;
      cursor: pointer;
      opacity: 0;
      transition: opacity 120ms ease, background 120ms ease, color 120ms ease;
    }
    .session-item:hover .session-item-kebab,
    .session-item[data-active="true"] .session-item-kebab { opacity: 1; }
    .session-item-kebab:hover { background: var(--surface-hover); color: var(--text); }
    .session-item[data-archived="true"] { display: none; }

    @keyframes pulse-dot {
      0%, 100% { box-shadow: 0 0 0 0 var(--accent); }
      50% { box-shadow: 0 0 0 5px oklch(19% 0.012 92 / 0); }
    }

    .drawer-footer {
      display: flex;
      align-items: center;
      gap: 6px;
      padding: 7px 4px 2px;
      font-size: 0.68rem;
      color: var(--text-muted);
      border-top: 1px solid var(--border);
    }
    .drawer-footer code {
      font-family: var(--mono);
      font-size: 0.72rem;
      color: var(--text-soft);
    }
    .drawer-footer .footer-text {
      display: inline-flex; align-items: center; gap: 6px;
      flex: 1; min-width: 0;
      white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
    }
    .footer-dot {
      width: 8px; height: 8px; border-radius: 50%;
      background: var(--success);
      box-shadow: 0 0 0 0 rgba(22, 163, 74, 0.45);
      animation: footer-pulse 2.6s ease-in-out infinite;
    }
    .footer-dot[data-state="offline"] { background: var(--danger); animation: none; }
    .footer-dot[data-state="degraded"] { background: var(--warning); animation: none; }

    @keyframes footer-pulse {
      0%, 100% { box-shadow: 0 0 0 0 rgba(22, 163, 74, 0.35); }
      50% { box-shadow: 0 0 0 5px rgba(22, 163, 74, 0); }
    }

    .theme-toggle .theme-icon-moon { display: none; }
    :root[data-theme="dark"] .theme-toggle .theme-icon-sun { display: none; }
    :root[data-theme="dark"] .theme-toggle .theme-icon-moon { display: inline-block; }

    .install-button { color: var(--accent); }

    /* ===== Stage / Topbar ===== */
    .stage {
      position: relative;
      display: grid;
      grid-template-rows: auto auto minmax(0, 1fr) auto;
      min-width: 0;
      min-height: 0;
      max-width: 100vw;
      overflow-x: hidden;
      background: var(--canvas);
    }
    .topbar { grid-row: 1; }
    .live-strip { grid-row: 2; }
    .car-mode-panel,
    .chat-stream { grid-row: 3; }
    .composer-dock { grid-row: 4; }

    .topbar {
      display: flex;
      align-items: center;
      gap: 7px;
      min-width: 0;
      width: min(860px, calc(100% - 24px));
      margin: 10px auto 0;
      padding: 6px 7px;
      border: 1px solid color-mix(in srgb, var(--border) 78%, transparent);
      border-radius: 14px;
      background: color-mix(in srgb, var(--surface) 92%, var(--canvas));
      box-shadow: 0 8px 22px oklch(19% 0.012 92 / 0.055);
      position: sticky;
      top: 0;
      z-index: 20;
    }
    :root[data-theme="dark"] .topbar {
      background: color-mix(in srgb, var(--surface) 90%, var(--canvas));
      box-shadow: 0 10px 28px oklch(9% 0.01 92 / 0.28);
    }
    :root[data-native-companion="true"] .topbar {
      margin-top: calc(7px + env(safe-area-inset-top));
      top: env(safe-area-inset-top);
    }

    .icon-button {
      background: transparent;
      border: 1px solid var(--border);
      color: var(--text-soft);
      width: 31px; height: 31px;
      border-radius: 11px;
      display: grid;
      place-items: center;
      cursor: pointer;
      transition: background 120ms ease, color 120ms ease, transform 120ms ease, border 120ms ease;
    }
    .icon-button:hover { background: var(--surface); color: var(--text); border-color: var(--border-strong); }
    .icon-button:active { transform: scale(0.95); }
    .icon-button.stop {
      background: var(--danger-soft);
      border-color: transparent;
      color: var(--danger);
    }
    .icon-button.stop:hover { background: rgba(220, 38, 38, 0.18); }
    .car-mode-toggle[data-active="true"] {
      background: var(--text);
      border-color: var(--text);
      color: var(--canvas);
    }
    body[data-car-mode="true"] .topbar {
      width: min(680px, calc(100% - 20px));
    }
    body[data-car-mode="true"] .topbar-subtitle {
      display: none;
    }
    body[data-car-mode="true"] .live-strip {
      display: none;
    }

    #menu-button { display: none; }

    .topbar-title {
      flex: 1;
      min-width: 0;
      display: grid;
      line-height: 1.2;
    }
    .topbar-title h1 {
      font-family: var(--display);
      font-size: 0.94rem;
      font-weight: 640;
      white-space: nowrap;
      overflow: hidden;
      text-overflow: ellipsis;
      cursor: text;
    }
    .topbar-title h1[contenteditable="true"] {
      outline: 1px dashed var(--border-strong);
      outline-offset: 4px;
      border-radius: 6px;
      cursor: text;
    }
    .topbar-subtitle {
      font-size: 0.7rem;
      color: var(--text-muted);
      white-space: nowrap;
      overflow: hidden;
      text-overflow: ellipsis;
    }

    .topbar-actions { display: flex; gap: 5px; flex-shrink: 0; min-width: 0; }

    .live-strip {
      width: min(900px, calc(100% - 32px));
      margin: 7px auto 0;
      padding: 6px 8px;
      border: 1px solid color-mix(in srgb, var(--border) 78%, transparent);
      border-radius: 12px;
      background: color-mix(in srgb, var(--surface) 88%, var(--canvas));
      display: grid;
      grid-template-columns: minmax(0, 1fr) auto;
      gap: 10px;
      align-items: center;
      min-width: 0;
      box-shadow: var(--shadow-sm);
    }
    .live-strip[data-state="running"],
    .live-strip[data-state="thinking"],
    .live-strip[data-state="streaming"],
    .live-strip[data-state="command"],
    .live-strip[data-state="tool"],
    .live-strip[data-state="patch"] {
      border-color: var(--border-strong);
      background: color-mix(in srgb, var(--surface) 86%, transparent);
    }
    .live-strip[data-state="attention"],
    .live-strip[data-state="error"] {
      border-color: color-mix(in srgb, var(--warning) 38%, transparent);
      background: color-mix(in srgb, var(--warning) 7%, var(--surface));
    }
    .live-strip-main {
      display: flex;
      align-items: center;
      gap: 9px;
      min-width: 0;
    }
    .state-glyph {
      width: 22px;
      height: 22px;
      border-radius: 999px;
      display: inline-grid;
      place-items: center;
      flex: 0 0 auto;
      color: var(--text-muted);
      background: var(--surface-sunk);
      border: 1px solid var(--border);
      font-size: 0.78rem;
      font-weight: 780;
      line-height: 1;
    }
    .state-glyph[data-state="thinking"],
    .state-glyph[data-state="streaming"] {
      color: var(--accent);
      background: var(--accent-tint);
      border-color: color-mix(in srgb, var(--accent) 38%, var(--border));
    }
    .state-glyph[data-state="command"],
    .state-glyph[data-state="tool"],
    .state-glyph[data-state="patch"],
    .state-glyph[data-state="running"] {
      color: var(--warning);
      background: color-mix(in srgb, var(--warning) 10%, var(--surface));
      border-color: color-mix(in srgb, var(--warning) 38%, var(--border));
    }
    .state-glyph[data-state="ready"] {
      color: var(--success);
      background: color-mix(in srgb, var(--success) 9%, var(--surface));
      border-color: color-mix(in srgb, var(--success) 34%, var(--border));
    }
    .state-glyph[data-state="attention"],
    .state-glyph[data-state="error"] {
      color: var(--danger);
      background: color-mix(in srgb, var(--danger) 9%, var(--surface));
      border-color: color-mix(in srgb, var(--danger) 38%, var(--border));
    }
    .live-dot {
      width: 9px;
      height: 9px;
      border-radius: 999px;
      background: var(--text-faint);
      flex: 0 0 auto;
    }
    .live-strip[data-live="true"] .live-dot {
      background: var(--accent);
      box-shadow: 0 0 0 0 var(--accent-tint);
      animation: pulse-dot 1.25s ease-in-out infinite;
    }
    .live-strip[data-state="command"] .live-dot,
    .live-strip[data-state="tool"] .live-dot,
    .live-strip[data-state="patch"] .live-dot,
    .live-strip[data-state="running"] .live-dot {
      background: var(--warning);
      box-shadow: 0 0 0 0 color-mix(in srgb, var(--warning) 22%, transparent);
    }
    .live-strip[data-state="ready"] .live-dot {
      background: var(--success);
      animation: none;
      box-shadow: none;
    }
    .live-strip[data-state="attention"] .live-dot,
    .live-strip[data-state="error"] .live-dot {
      background: var(--danger);
      animation: none;
    }
    .live-copy {
      display: grid;
      gap: 2px;
      min-width: 0;
    }
    .live-title-row {
      display: flex;
      align-items: center;
      gap: 7px;
      min-width: 0;
    }
    .live-title {
      font-size: 0.84rem;
      font-weight: 620;
      color: var(--text);
      white-space: nowrap;
      overflow: hidden;
      text-overflow: ellipsis;
    }
    .live-source {
      font-family: var(--mono);
      font-size: 0.66rem;
      color: var(--text-faint);
      text-transform: uppercase;
      letter-spacing: 0;
      white-space: nowrap;
    }
    .live-detail {
      color: var(--text-muted);
      font-size: 0.76rem;
      line-height: 1.28;
      white-space: nowrap;
      overflow: hidden;
      text-overflow: ellipsis;
    }
    .live-metrics {
      display: flex;
      align-items: center;
      gap: 5px;
      min-width: 0;
      overflow: hidden;
    }
    .live-metrics-list {
      display: contents;
    }
    .live-metric {
      display: inline-flex;
      align-items: center;
      min-height: 22px;
      padding: 2px 7px;
      border-radius: var(--radius-pill);
      background: var(--surface-sunk);
      border: 1px solid var(--border);
      color: var(--text-muted);
      font-size: 0.68rem;
      font-weight: 600;
      white-space: nowrap;
    }
    .live-action {
      border: 1px solid var(--border);
      background: transparent;
      color: var(--text-soft);
      border-radius: 8px;
      min-height: 25px;
      padding: 4px 8px;
      font-size: 0.72rem;
      font-weight: 650;
      cursor: pointer;
      white-space: nowrap;
    }
    .live-action:hover {
      background: var(--surface-hover);
      color: var(--text);
      border-color: var(--border-strong);
    }

    /* ===== Car mode ===== */
    .car-mode-panel {
      min-height: 0;
      padding: 18px max(18px, env(safe-area-inset-right)) 12px max(18px, env(safe-area-inset-left));
      overflow-y: auto;
      display: grid;
      place-items: center;
    }
    .car-mode-panel[hidden] { display: none; }
    .car-mode-shell {
      width: min(680px, 100%);
      min-height: min(620px, 100%);
      display: grid;
      grid-template-rows: auto minmax(0, 1fr) auto auto;
      gap: 22px;
      align-content: center;
      padding: clamp(18px, 5vw, 32px);
      border-radius: 18px;
      border: 1px solid color-mix(in srgb, var(--border-strong) 70%, transparent);
      background: color-mix(in srgb, var(--surface) 94%, var(--canvas));
      box-shadow: 0 18px 54px oklch(19% 0.012 92 / 0.10);
    }
    :root[data-theme="dark"] .car-mode-shell {
      background: color-mix(in srgb, var(--surface) 94%, var(--canvas));
      box-shadow: 0 22px 66px oklch(9% 0.01 92 / 0.42);
    }
    .car-status-row {
      display: flex;
      align-items: center;
      gap: 12px;
      min-width: 0;
    }
    .car-status-glyph {
      width: 42px;
      height: 42px;
      border-radius: 999px;
      display: inline-grid;
      place-items: center;
      flex: 0 0 auto;
      color: var(--text-muted);
      background: var(--surface-sunk);
      border: 1px solid var(--border);
      font-size: 1.1rem;
      font-weight: 800;
      line-height: 1;
    }
    .car-status-glyph[data-state="listening"] {
      color: var(--danger);
      background: var(--danger-soft);
      border-color: color-mix(in srgb, var(--danger) 42%, var(--border));
      animation: car-pulse 1.1s ease-in-out infinite;
    }
    .car-status-glyph[data-state="thinking"],
    .car-status-glyph[data-state="streaming"] {
      color: var(--accent);
      background: var(--accent-tint);
      border-color: color-mix(in srgb, var(--accent) 38%, var(--border));
      animation: car-pulse 1.35s ease-in-out infinite;
    }
    .car-status-glyph[data-state="working"],
    .car-status-glyph[data-state="running"],
    .car-status-glyph[data-state="command"],
    .car-status-glyph[data-state="tool"],
    .car-status-glyph[data-state="patch"] {
      color: var(--warning);
      background: color-mix(in srgb, var(--warning) 10%, var(--surface));
      border-color: color-mix(in srgb, var(--warning) 42%, var(--border));
      animation: car-pulse 1.1s ease-in-out infinite;
    }
    .car-status-glyph[data-state="attention"],
    .car-status-glyph[data-state="error"] {
      color: var(--danger);
      background: color-mix(in srgb, var(--danger) 9%, var(--surface));
      border-color: color-mix(in srgb, var(--danger) 42%, var(--border));
    }
    .car-status-glyph[data-state="ready"] {
      color: var(--success);
      background: color-mix(in srgb, var(--success) 10%, var(--surface));
      border-color: color-mix(in srgb, var(--success) 38%, var(--border));
    }
    @keyframes car-pulse {
      0%, 100% { box-shadow: 0 0 0 0 currentColor; }
      50% { box-shadow: 0 0 0 8px oklch(9% 0.01 92 / 0); }
    }
    .car-status-copy {
      min-width: 0;
      display: grid;
      gap: 2px;
    }
    .car-status-label {
      font-family: var(--display);
      font-size: clamp(1.18rem, 4vw, 1.55rem);
      font-weight: 660;
      line-height: 1.08;
      color: var(--text);
    }
    .car-status-detail {
      font-size: 0.88rem;
      line-height: 1.32;
      color: var(--text-muted);
      overflow-wrap: anywhere;
    }
    .car-main {
      display: grid;
      align-content: center;
      gap: 14px;
      min-width: 0;
    }
    .car-main h2 {
      font-family: var(--display);
      font-size: clamp(2rem, 9vw, 4rem);
      line-height: 0.98;
      font-weight: 680;
      letter-spacing: 0;
      color: var(--text);
      overflow-wrap: anywhere;
    }
    .car-main p {
      color: var(--text-soft);
      font-size: clamp(1.05rem, 3.4vw, 1.35rem);
      line-height: 1.42;
      max-width: 34em;
    }
    .car-mode-actions {
      display: grid;
      grid-template-columns: 1.15fr 1fr 1fr 1fr;
      gap: 10px;
      min-width: 0;
    }
    .car-action {
      min-width: 0;
      min-height: 74px;
      border: 1px solid var(--border);
      border-radius: 20px;
      background: color-mix(in srgb, var(--surface-sunk) 58%, transparent);
      color: var(--text-soft);
      display: inline-flex;
      align-items: center;
      justify-content: center;
      gap: 10px;
      padding: 12px 14px;
      font-size: clamp(0.95rem, 3vw, 1.1rem);
      font-weight: 680;
      cursor: pointer;
      transition: transform 120ms ease, background 120ms ease, border 120ms ease, color 120ms ease;
    }
    .car-action:hover {
      background: var(--surface-hover);
      border-color: var(--border-strong);
      color: var(--text);
    }
    .car-action:active { transform: scale(0.97); }
    .car-action-primary {
      background: var(--text);
      color: var(--canvas);
      border-color: var(--text);
    }
    .car-action-primary:hover {
      color: var(--canvas);
      background: var(--accent-strong);
    }
    .car-action-primary[data-recording="true"] {
      background: var(--danger);
      border-color: var(--danger);
      color: var(--on-solid);
      animation: mic-pulse 1.2s ease-in-out infinite;
    }
    .car-action[data-active="true"] {
      color: var(--success);
      border-color: color-mix(in srgb, var(--success) 42%, var(--border));
      background: color-mix(in srgb, var(--success) 10%, var(--surface));
    }
    .car-action[data-active="true"]:hover {
      color: var(--success);
      border-color: color-mix(in srgb, var(--success) 55%, var(--border));
    }
    .car-verbosity {
      justify-self: center;
      display: inline-flex;
      align-items: center;
      gap: 4px;
      padding: 4px;
      border: 1px solid var(--border);
      border-radius: 999px;
      background: color-mix(in srgb, var(--surface-sunk) 68%, transparent);
      min-width: 0;
    }
    .car-verbosity button {
      min-height: 34px;
      padding: 6px 12px;
      border: none;
      border-radius: 999px;
      background: transparent;
      color: var(--text-muted);
      font-size: 0.82rem;
      font-weight: 650;
      cursor: pointer;
      white-space: nowrap;
    }
    .car-verbosity button[data-active="true"] {
      background: var(--surface);
      color: var(--text);
      box-shadow: var(--shadow-sm);
    }
    body[data-car-mode="true"] .chat-stream {
      display: none;
    }
    body[data-car-mode="true"] .composer-dock {
      display: none;
    }
    body[data-car-mode="true"] .runtime-bar,
    body[data-car-mode="true"] .attachment-tray,
    body[data-car-mode="true"] .composer-hint {
      display: none;
    }
    body[data-car-mode="true"] .composer {
      width: min(680px, calc(100% - 20px));
      grid-template-columns: auto minmax(0, 1fr) auto;
    }
    body[data-car-mode="true"] .attachment-button {
      display: none;
    }
    body[data-car-mode="true"] .composer textarea {
      min-height: 34px;
      font-size: 1rem;
    }
    @media (max-width: 560px) {
      .car-mode-shell {
        min-height: min(560px, 100%);
        border-radius: 24px;
        gap: 18px;
      }
      .car-mode-actions {
        grid-template-columns: 1fr;
      }
      .car-action {
        min-height: 64px;
      }
      .car-verbosity {
        width: 100%;
        justify-content: stretch;
      }
      .car-verbosity button {
        flex: 1;
        padding-inline: 8px;
      }
    }

    /* ===== Chat stream ===== */
    .chat-stream {
      overflow-y: auto;
      overflow-x: hidden;
      padding: 14px max(16px, env(safe-area-inset-right)) 108px max(16px, env(safe-area-inset-left));
      scroll-behavior: auto;
      scroll-padding-block-end: 108px;
      overscroll-behavior: contain;
      min-width: 0;
      max-width: 100%;
    }
    .chat-stream:focus { outline: none; }

    .stage-inner {
      width: min(860px, 100%);
      max-width: 860px;
      margin: 0 auto;
      display: grid;
      gap: 16px;
      min-width: 0;
    }

    /* Empty state */
    .empty-state {
      display: grid;
      gap: 14px;
      width: min(720px, 100%);
      max-width: 720px;
      margin: 42px auto 0;
      text-align: center;
      animation: fade-in 280ms ease-out;
    }
    .empty-state h2 {
      font-family: var(--display);
      font-size: clamp(1.55rem, 5vw, 2.15rem);
      font-weight: 620;
      line-height: 1.12;
    }
    .empty-state p {
      color: var(--text-muted);
      line-height: 1.5;
      font-size: 0.95rem;
      width: min(560px, 100%);
      margin: 0 auto;
    }
    .empty-hero {
      display: grid;
      place-items: center;
      gap: 8px;
      padding: 10px 0 0;
    }
    .empty-hero-mark {
      width: 54px; height: 54px;
      border-radius: 14px;
      object-fit: cover;
      box-shadow: 0 2px 8px oklch(19% 0.012 92 / 0.12);
      filter: grayscale(0.88) contrast(1.04);
    }

    .suggestion-grid {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));
      gap: 8px;
      margin-top: 10px;
      min-width: 0;
    }
    .suggestion-card {
      padding: 11px 12px;
      background: color-mix(in srgb, var(--surface) 78%, transparent);
      border: 1px solid var(--border);
      border-radius: 10px;
      cursor: pointer;
      text-align: left;
      display: grid;
      gap: 4px;
      color: var(--text-soft);
      transition: background 140ms ease, border 140ms ease, transform 140ms ease;
    }
    .suggestion-card:hover {
      transform: translateY(-2px);
      border-color: var(--border-strong);
      background: var(--surface);
    }
    .suggestion-card strong { color: var(--text); font-weight: 590; font-size: 0.92rem; }
    .suggestion-card span { font-size: 0.76rem; color: var(--text-muted); line-height: 1.3; }

    /* Segments */
    .segment {
      animation: fade-in 240ms ease-out;
      min-width: 0;
    }
    .segment-user {
      display: grid;
      justify-content: end;
      margin-left: auto;
      width: fit-content;
      max-width: 680px;
      min-width: 0;
    }
    .segment-user.segment-optimistic { opacity: 0.78; }
    .segment-user.segment-failed { opacity: 0.9; }

    .user-bubble {
      background: var(--user-bubble-bg);
      color: var(--user-bubble-fg);
      padding: 8px 12px;
      border-radius: 18px;
      font-size: 0.92rem;
      line-height: 1.42;
      box-shadow: none;
      max-width: min(88vw, 680px);
      white-space: pre-wrap;
      overflow-wrap: anywhere;
      word-break: break-word;
    }
    .segment-user .message-meta {
      display: flex;
      justify-content: flex-end;
      gap: 6px;
      align-items: center;
      margin-top: 3px;
      font-size: 0.68rem;
      color: var(--text-faint);
    }
    .segment-user .message-meta button {
      background: transparent;
      border: none;
      color: inherit;
      cursor: pointer;
      padding: 2px 6px;
      border-radius: 6px;
    }
    .segment-user .message-meta button:hover { background: var(--surface-hover); color: var(--text); }
    .segment-user.segment-failed .message-meta { color: var(--danger); }

    .assistant-block {
      display: grid;
      gap: 9px;
      padding: 2px 0 0;
      background: transparent;
      border: 1px solid transparent;
      border-radius: 0;
      box-shadow: none;
      overflow: hidden;
      min-width: 0;
      max-width: 100%;
    }
    .assistant-block.is-final {
      border-color: transparent;
      background: transparent;
    }
    :root[data-theme="dark"] .assistant-block.is-final {
      border-color: transparent;
      background: transparent;
    }
    .assistant-block.is-working,
    .assistant-block.is-pending {
      border-color: transparent;
      background: transparent;
    }
    .assistant-block.is-error {
      border-color: transparent;
      background: transparent;
    }
    .assistant-block.is-warning {
      border-color: transparent;
      background: transparent;
    }

    .assistant-block-header {
      display: flex;
      align-items: flex-start;
      gap: 9px;
      font-size: 0.72rem;
      color: var(--text-muted);
    }
    .assistant-header-copy {
      min-width: 0;
      display: grid;
      gap: 2px;
    }
    .assistant-meta {
      display: flex;
      flex-wrap: wrap;
      gap: 4px;
      font-size: 0.74rem;
      color: var(--text-muted);
    }
    .assistant-avatar {
      width: 26px; height: 26px;
      border-radius: 8px;
      object-fit: cover;
      filter: grayscale(0.88) contrast(1.04);
      flex-shrink: 0;
    }
    .kind-chip {
      display: inline-flex;
      align-items: center;
      gap: 4px;
      padding: 1px 6px 2px;
      border-radius: 6px;
      font-size: 0.62rem;
      font-weight: 560;
      letter-spacing: 0;
      text-transform: uppercase;
      background: color-mix(in srgb, var(--surface-sunk) 54%, transparent);
      color: var(--text-muted);
      border: 1px solid var(--border);
    }
    .kind-reasoning,
    .kind-command,
    .kind-patch,
    .kind-final,
    .kind-tool,
    .kind-system {
      background: color-mix(in srgb, var(--surface-sunk) 56%, transparent);
      color: var(--text-muted);
      border-color: var(--border);
    }
    .kind-final {
      background: var(--text);
      color: var(--canvas);
      border-color: var(--text);
    }

    .assistant-title {
      font-family: var(--display);
      font-weight: 620;
      font-size: 0.94rem;
      color: var(--text);
      letter-spacing: 0;
    }

    .assistant-body {
      color: var(--text-soft);
      font-size: 0.96rem;
      line-height: 1.58;
      overflow-wrap: anywhere;
      min-width: 0;
      max-width: 100%;
    }
    .assistant-response {
      color: var(--text);
      font-size: 0.98rem;
      line-height: 1.64;
    }
    .assistant-response.is-streaming-preview {
      color: var(--text-soft);
    }
    .assistant-response.is-error,
    .assistant-response.is-warning {
      padding: 10px 12px;
      border-radius: 8px;
      border: 1px solid var(--border);
      background: color-mix(in srgb, var(--surface-sunk) 64%, transparent);
    }
    .assistant-timeline {
      display: grid;
      gap: 10px;
      min-width: 0;
    }
    .assistant-timeline-item {
      min-width: 0;
      max-width: 100%;
    }
    .assistant-timeline-text {
      display: grid;
      gap: 3px;
      position: relative;
    }
    .assistant-timeline-text.is-speaking {
      border: 1px solid color-mix(in srgb, var(--accent) 24%, var(--border));
      padding: 6px 8px;
      background: color-mix(in srgb, var(--accent) 7%, transparent);
      border-radius: 8px;
    }
    .assistant-timeline-text[data-speak-key] .assistant-response {
      padding-right: 34px;
    }
    .assistant-response-actions {
      display: flex;
      align-items: center;
      gap: 6px;
      position: absolute;
      top: -2px;
      right: 0;
      z-index: 2;
      opacity: 0;
      transform: translateY(-2px);
      transition: opacity 140ms ease, transform 140ms ease;
      pointer-events: none;
    }
    .assistant-timeline-text:hover .assistant-response-actions,
    .assistant-timeline-text:focus-within .assistant-response-actions,
    .assistant-timeline-text.is-speaking .assistant-response-actions {
      opacity: 1;
      transform: translateY(0);
      pointer-events: auto;
    }
    .speak-message,
    .speak-stop {
      display: inline-flex;
      align-items: center;
      justify-content: center;
      width: 26px;
      height: 26px;
      padding: 0;
      border-radius: 999px;
      border: 1px solid var(--border);
      background: color-mix(in srgb, var(--surface) 86%, transparent);
      color: var(--text-muted);
      font: inherit;
      line-height: 1;
      cursor: pointer;
      box-shadow: 0 4px 14px color-mix(in srgb, var(--shadow) 18%, transparent);
    }
    .speak-message:hover,
    .speak-stop:hover {
      color: var(--text);
      border-color: var(--border-strong);
      background: var(--surface-hover);
    }
    .speak-message svg,
    .speak-stop svg {
      width: 13px;
      height: 13px;
      flex: 0 0 auto;
    }
    .assistant-timeline-text.is-speaking .speak-message {
      color: var(--accent-strong);
      border-color: color-mix(in srgb, var(--accent) 38%, var(--border));
      background: color-mix(in srgb, var(--accent) 10%, var(--surface));
    }
    @media (hover: none) {
      .assistant-response-actions {
        opacity: 0.68;
        transform: none;
        pointer-events: auto;
      }
    }
    .assistant-timeline-text.is-reasoning .assistant-response {
      color: var(--text-soft);
    }
    .assistant-timeline-text.is-final .assistant-response {
      color: var(--text);
    }
    .assistant-timeline-text.is-system .assistant-response {
      color: var(--text-muted);
      font-size: 0.9rem;
    }
    .assistant-timeline-label {
      display: inline-flex;
      align-items: center;
      gap: 6px;
      width: fit-content;
      max-width: 100%;
      color: var(--text-muted);
      font-size: 0.74rem;
      font-weight: 620;
      line-height: 1.2;
      letter-spacing: 0;
    }
    .assistant-timeline-label::before {
      content: "";
      width: 5px;
      height: 5px;
      border-radius: 999px;
      background: var(--text-faint);
    }
    .assistant-timeline-text.is-final .assistant-timeline-label::before {
      background: var(--accent);
    }
    .assistant-timeline-text.is-error .assistant-timeline-label::before {
      background: #ef4444;
    }
    .assistant-timeline-text.is-warning .assistant-timeline-label::before {
      background: #d97706;
    }
    .assistant-timeline-action {
      margin-top: 0;
    }
    .assistant-timeline-action > summary {
      min-height: 34px;
    }
    .assistant-inline-status {
      display: inline-flex;
      align-items: center;
      gap: 6px;
      margin-bottom: 8px;
      font-size: 0.8rem;
      font-weight: 600;
      color: var(--text-muted);
      letter-spacing: 0;
    }
    .assistant-body h1, .assistant-body h2, .assistant-body h3 {
      color: var(--text);
      font-weight: 700;
      letter-spacing: 0;
      margin-top: 10px;
    }
    .assistant-body h1 { font-size: 1.08rem; }
    .assistant-body h2 { font-size: 1rem; }
    .assistant-body h3 { font-size: 0.94rem; }
    .assistant-body p { margin: 0.32em 0; }
    .assistant-body ul, .assistant-body ol { margin: 0.35em 0; padding-left: 1.15em; }
    .assistant-body li { margin: 0.16em 0; }
    .assistant-body blockquote {
      margin: 0.45em 0;
      padding: 6px 9px;
      border: 1px solid color-mix(in srgb, var(--accent) 24%, var(--border));
      background: var(--accent-soft);
      border-radius: 5px;
      color: var(--text);
    }
    .assistant-body a { color: var(--accent-strong); }
    .assistant-body hr {
      border: none;
      border-top: 1px solid var(--border);
      margin: 10px 0;
    }
    .assistant-body table {
      width: 100%;
      max-width: 100%;
      border-collapse: collapse;
      table-layout: fixed;
      font-size: 0.82rem;
      margin: 0.5em 0;
      border: 1px solid var(--border);
      border-radius: 8px;
      display: table;
      overflow: hidden;
    }
    .assistant-body th, .assistant-body td {
      padding: 5px 8px;
      border-bottom: 1px solid var(--border);
      text-align: left;
      vertical-align: top;
      overflow-wrap: anywhere;
      word-break: break-word;
    }
    .assistant-body th { background: var(--surface-sunk); font-weight: 600; }

    code {
      font-family: var(--mono);
      font-size: 0.88em;
      padding: 2px 5px;
      background: var(--surface-sunk);
      border-radius: 6px;
      border: 1px solid var(--border);
    }
    .assistant-body pre {
      margin: 0.6em 0;
      padding: 0;
      background: transparent;
    }
    .code-block {
      position: relative;
      border-radius: 8px;
      overflow: hidden;
      max-width: 100%;
      min-width: 0;
      background: var(--code-bg);
      color: var(--code-fg);
      border: 1px solid var(--border-strong);
    }
    .code-block-head {
      display: flex;
      align-items: center;
      justify-content: space-between;
      padding: 5px 9px;
      font-family: var(--mono);
      font-size: 0.72rem;
      letter-spacing: 0;
      color: #94a3b8;
      background: rgba(255, 255, 255, 0.045);
      border-bottom: 1px solid rgba(148, 163, 184, 0.16);
    }
    .code-block-lang { text-transform: uppercase; font-weight: 600; }
    .code-copy {
      background: transparent;
      border: 1px solid transparent;
      color: #cbd5e1;
      font-size: 0.7rem;
      padding: 2px 8px;
      border-radius: 6px;
      cursor: pointer;
      display: inline-flex;
      align-items: center;
      gap: 4px;
      font-family: var(--sans);
    }
    .code-copy:hover { border-color: rgba(148, 163, 184, 0.3); background: rgba(148, 163, 184, 0.08); }
    .code-block pre {
      margin: 0;
      padding: 9px 11px;
      overflow-x: hidden;
      white-space: pre-wrap;
      overflow-wrap: anywhere;
      font-family: var(--mono);
      font-size: 0.78rem;
      line-height: 1.42;
      color: var(--code-fg);
      background: transparent;
      border: none;
    }
    .code-block pre code {
      background: transparent;
      border: none;
      padding: 0;
      color: inherit;
      font-size: inherit;
      white-space: pre-wrap;
      overflow-wrap: anywhere;
    }

    .tok-kw { color: var(--syntax-keyword); font-weight: 500; }
    .tok-str { color: var(--syntax-string); }
    .tok-num { color: var(--syntax-number); }
    .tok-cmt { color: var(--syntax-comment); font-style: italic; }
    .tok-fn { color: var(--syntax-func); }
    .tok-ty { color: var(--syntax-type); }

    /* Diff viewer */
    .diff-block {
      display: grid;
      font-family: var(--mono);
      font-size: 0.76rem;
      border-radius: 8px;
      overflow: hidden;
      border: 1px solid var(--border-strong);
      background: var(--surface);
      max-width: 100%;
      min-width: 0;
    }
    .diff-head {
      padding: 5px 9px;
      background: var(--surface-sunk);
      font-size: 0.72rem;
      color: var(--text-muted);
      letter-spacing: 0;
      text-transform: uppercase;
      font-weight: 600;
      border-bottom: 1px solid var(--border);
    }
    .diff-body { padding: 4px 0; overflow-x: auto; min-width: 0; }
    .diff-line {
      display: grid;
      grid-template-columns: 32px minmax(0, 1fr);
      align-items: baseline;
      padding: 0 8px;
      line-height: 1.38;
    }
    .diff-gutter {
      color: var(--text-faint);
      font-size: 0.72rem;
      text-align: center;
      user-select: none;
    }
    .diff-add { background: var(--diff-add-bg); color: var(--diff-add-fg); }
    .diff-add .diff-gutter { color: var(--diff-add-fg); }
    .diff-del { background: var(--diff-del-bg); color: var(--diff-del-fg); }
    .diff-del .diff-gutter { color: var(--diff-del-fg); }
    .diff-hunk { background: var(--diff-hunk-bg); color: var(--diff-hunk-fg); font-weight: 600; }
    .diff-hunk .diff-gutter { color: var(--diff-hunk-fg); }

    /* Reasoning collapse */
    details.reasoning {
      background: transparent;
      padding: 0;
      border: none;
    }
    details.reasoning > summary {
      list-style: none;
      cursor: pointer;
      color: var(--text-muted);
      font-size: 0.82rem;
      padding: 4px 8px;
      border-radius: 8px;
      display: inline-flex;
      align-items: center;
      gap: 6px;
      transition: background 120ms ease;
    }
    details.reasoning > summary:hover { background: var(--surface-sunk); color: var(--text); }
    details.reasoning > summary::-webkit-details-marker { display: none; }
    details.reasoning > summary::before {
      content: "▸";
      transition: transform 140ms ease;
      font-size: 0.8rem;
    }
    details.reasoning[open] > summary::before { transform: rotate(90deg); }
    details.reasoning[open] > .reasoning-body { margin-top: 6px; }
    .assistant-support-item + .assistant-support-item { margin-top: 8px; }
    .assistant-process {
      margin-top: 2px;
    }
    .assistant-process-body {
      display: grid;
      gap: 8px;
    }
    .assistant-process-group {
      border-style: dashed;
      background: color-mix(in srgb, var(--surface) 36%, transparent);
    }
    .assistant-process-group > summary {
      min-height: 32px;
      color: var(--text-muted);
    }
    .assistant-process-group-body {
      gap: 7px;
    }
    .assistant-process-row {
      display: grid;
      gap: 6px;
      padding: 8px;
      border: 1px solid color-mix(in srgb, var(--border) 76%, transparent);
      border-radius: 8px;
      background: color-mix(in srgb, var(--surface) 52%, transparent);
    }
    .assistant-process-row-title {
      color: var(--text-muted);
      font-size: 0.76rem;
      font-weight: 620;
      line-height: 1.25;
    }
    .assistant-process-row-content {
      display: grid;
      gap: 7px;
      min-width: 0;
    }
    .assistant-process-row-content > .activity-collapsible {
      margin-top: 0;
    }

    .activity-collapsible {
      margin-top: 8px;
      border: 1px solid var(--border);
      border-radius: 9px;
      background: color-mix(in srgb, var(--surface) 48%, transparent);
      overflow: hidden;
    }
    .activity-collapsible > summary {
      cursor: pointer;
      list-style: none;
      padding: 7px 10px;
      color: var(--text-muted);
      font-size: 0.78rem;
      font-weight: 580;
      display: flex;
      align-items: center;
      gap: 7px;
    }
    .activity-collapsible > summary::-webkit-details-marker { display: none; }
    .activity-collapsible > summary::before {
      content: "▸";
      font-size: 0.74rem;
      transition: transform 140ms ease;
    }
    .activity-collapsible[open] > summary::before { transform: rotate(90deg); }
    .activity-collapsible-body {
      border-top: 1px solid var(--border);
      padding: 9px;
      background: color-mix(in srgb, var(--surface-sunk) 42%, transparent);
    }
    .activity-summary-row {
      color: var(--text-muted);
      font-size: 0.82rem;
      padding: 6px 0;
    }
    .activity-hidden-note {
      color: var(--text-faint);
      font-size: 0.76rem;
      margin-top: 4px;
    }

    .approval-card {
      display: grid;
      gap: 10px;
      padding: 12px;
      border: 1px solid var(--border-strong);
      border-radius: 9px;
      background: color-mix(in srgb, var(--warning) 7%, var(--surface));
    }
    .approval-card-title {
      display: flex;
      align-items: center;
      gap: 7px;
      font-size: 0.84rem;
      font-weight: 620;
      color: var(--text);
    }
    .approval-card-detail {
      white-space: pre-wrap;
      overflow-wrap: anywhere;
      color: var(--text-muted);
      font-family: var(--mono);
      font-size: 0.72rem;
      line-height: 1.42;
      max-height: 180px;
      overflow: auto;
      border: 1px solid var(--border);
      border-radius: 7px;
      background: color-mix(in srgb, var(--surface-sunk) 58%, transparent);
      padding: 8px;
    }
    .approval-actions {
      display: flex;
      flex-wrap: wrap;
      gap: 7px;
    }
    .approval-action {
      min-height: 30px;
      border-radius: 8px;
      border: 1px solid var(--border);
      background: var(--surface);
      color: var(--text-soft);
      font-size: 0.76rem;
      font-weight: 620;
      padding: 5px 9px;
      cursor: pointer;
    }
    .approval-action:hover {
      border-color: var(--border-strong);
      color: var(--text);
      background: var(--surface-hover);
    }
    .approval-action.primary {
      background: var(--text);
      color: var(--canvas);
      border-color: var(--text);
    }
    .approval-action.danger {
      color: var(--danger);
      border-color: color-mix(in srgb, var(--danger) 35%, transparent);
      background: var(--danger-soft);
    }

    /* Files */
    .related-files {
      display: flex;
      flex-wrap: wrap;
      gap: 8px;
      margin-top: 6px;
    }
    .file-card {
      display: inline-flex;
      align-items: center;
      gap: 6px;
      padding: 6px 10px 6px 8px;
      background: color-mix(in srgb, var(--surface-sunk) 58%, transparent);
      color: var(--text-soft);
      border: 1px solid var(--border);
      border-radius: 8px;
      font-family: var(--mono);
      font-size: 0.78rem;
      cursor: pointer;
      text-decoration: none;
      transition: background 120ms ease, transform 120ms ease;
    }
    .file-card:hover { background: var(--surface); transform: translateY(-1px); }
    .local-file-link {
      display: inline-flex;
      align-items: center;
      max-width: 100%;
      padding: 1px 6px;
      border: 1px solid var(--border);
      border-radius: 7px;
      background: color-mix(in srgb, var(--surface-sunk) 64%, transparent);
      color: var(--link);
      font-family: var(--mono);
      font-size: 0.88em;
      text-decoration: none;
      vertical-align: baseline;
    }
    .local-file-link:hover {
      background: var(--surface);
      border-color: color-mix(in srgb, var(--link) 36%, var(--border));
    }
    .file-card-icon {
      width: 18px; height: 18px;
      border-radius: 5px;
      background: var(--surface);
      color: var(--text-muted);
      border: 1px solid var(--border);
      display: grid;
      place-items: center;
      font-size: 0.7rem;
      font-weight: 600;
    }

    .inline-image {
      display: block;
      max-width: 100%;
      max-height: 360px;
      margin: 8px 0;
      border-radius: 8px;
      border: 1px solid var(--border);
      background: var(--surface-sunk);
      object-fit: contain;
    }

    /* Command detail */
    .command-block {
      font-family: var(--mono);
      font-size: 0.85rem;
      background: var(--code-bg);
      color: var(--code-fg);
      border-radius: 8px;
      padding: 10px 12px;
      overflow-x: auto;
      white-space: pre-wrap;
    }
    .command-block.command-output {
      margin-top: 0;
      max-height: 340px;
    }

    /* Thinking indicator */
    .thinking {
      display: flex;
      align-items: center;
      gap: 8px;
      width: fit-content;
      max-width: min(680px, 100%);
      padding: 7px 10px;
      background: color-mix(in srgb, var(--surface) 54%, transparent);
      border: 1px solid var(--border);
      border-radius: 9px;
      box-shadow: none;
      color: var(--text-muted);
      font-size: 0.8rem;
      animation: fade-in 200ms ease-out;
    }
    .thinking-dots {
      display: inline-flex;
      gap: 4px;
    }
    .thinking-dots span {
      width: 7px; height: 7px;
      border-radius: 50%;
      background: var(--text-muted);
      animation: thinking-bounce 1.1s ease-in-out infinite;
    }
    .thinking-dots span:nth-child(2) { animation-delay: 0.12s; }
    .thinking-dots span:nth-child(3) { animation-delay: 0.24s; }

    @keyframes thinking-bounce {
      0%, 100% { transform: translateY(0); opacity: 0.5; }
      50% { transform: translateY(-4px); opacity: 1; }
    }

    /* Scroll bottom */
    .scroll-bottom {
      position: absolute;
      bottom: calc(104px + env(safe-area-inset-bottom));
      right: calc(18px + env(safe-area-inset-right));
      width: 36px; height: 36px;
      border-radius: 50%;
      background: var(--surface);
      color: var(--text);
      border: 1px solid var(--border-strong);
      display: grid;
      place-items: center;
      cursor: pointer;
      box-shadow: var(--shadow-md);
      transition: transform 120ms ease, opacity 160ms ease;
      z-index: 50;
    }
    .scroll-bottom:hover { transform: translateY(-2px); }
    .scroll-bottom-badge {
      position: absolute;
      top: -4px; right: -4px;
      background: var(--accent);
      color: var(--on-solid);
      border-radius: var(--radius-pill);
      font-size: 0.66rem;
      font-weight: 700;
      min-width: 18px;
      height: 18px;
      padding: 0 5px;
      display: inline-grid;
      place-items: center;
      box-shadow: 0 4px 10px oklch(19% 0.012 92 / 0.16);
    }

    /* Composer dock */
    .composer-dock {
      position: sticky;
      bottom: 0;
      left: 0;
      right: 0;
      padding: 6px max(14px, env(safe-area-inset-right)) calc(7px + env(safe-area-inset-bottom)) max(14px, env(safe-area-inset-left));
      background: linear-gradient(180deg, oklch(97.5% 0.006 92 / 0) 0%, color-mix(in srgb, var(--canvas) 84%, transparent) 46%, color-mix(in srgb, var(--canvas) 98%, transparent) 100%);
      z-index: 30;
      min-width: 0;
      max-width: 100%;
      overflow-x: hidden;
    }
    :root[data-theme="dark"] .composer-dock {
      background: linear-gradient(180deg, oklch(18% 0.010 92 / 0) 0%, color-mix(in srgb, var(--canvas) 82%, transparent) 46%, color-mix(in srgb, var(--canvas) 98%, transparent) 100%);
    }
    :root[data-native-companion="true"] .composer-dock {
      padding-bottom: 5px;
    }
    :root[data-native-companion="true"] .chat-stream {
      padding-bottom: 88px;
      scroll-padding-block-end: 88px;
    }

    .runtime-bar {
      width: min(860px, 100%);
      max-width: 860px;
      margin: 0 auto 5px;
      display: flex;
      align-items: center;
      gap: 5px;
      min-width: 0;
      overflow-x: auto;
      scrollbar-width: none;
      -webkit-overflow-scrolling: touch;
    }
    .runtime-bar::-webkit-scrollbar { display: none; }
    .runtime-pill,
    .runtime-icon-pill,
    .runtime-select-label,
    .runtime-access {
      min-height: 28px;
      display: inline-flex;
      align-items: center;
      gap: 6px;
      border: 1px solid var(--border);
      background: color-mix(in srgb, var(--surface) 86%, var(--canvas));
      color: var(--text-muted);
      border-radius: 8px;
      font-size: 0.7rem;
      font-weight: 560;
      padding: 3px 8px;
      white-space: nowrap;
      flex-shrink: 0;
    }
    .runtime-access {
      color: var(--text-muted);
      background: color-mix(in srgb, var(--surface) 62%, transparent);
      border-color: var(--border);
    }
    .runtime-pill,
    .runtime-icon-pill {
      cursor: pointer;
      transition: background 120ms ease, color 120ms ease, border 120ms ease, transform 120ms ease;
    }
    .runtime-pill:hover,
    .runtime-icon-pill:hover,
    .runtime-access:hover {
      background: var(--surface);
      color: var(--text);
      border-color: var(--border-strong);
    }
    .runtime-pill:active,
    .runtime-icon-pill:active,
    .runtime-access:active { transform: scale(0.97); }
    .runtime-pill[data-active="true"],
    .runtime-icon-pill[data-active="true"] {
      background: var(--text);
      color: var(--canvas);
      border-color: var(--text);
    }
    .runtime-busy-mode[data-mode="queue"] {
      background: var(--accent-soft);
      color: var(--accent-strong);
      border-color: var(--accent-tint);
    }
    .runtime-access {
      cursor: pointer;
      transition: background 120ms ease, color 120ms ease, border 120ms ease, transform 120ms ease;
    }
    .runtime-access[data-mode="onRequest"] {
      color: var(--text);
      background: var(--accent-soft);
      border-color: var(--border-strong);
    }
    .runtime-select-label span {
      color: var(--text-faint);
      font-family: var(--mono);
      font-size: 0.62rem;
      text-transform: uppercase;
      letter-spacing: 0;
    }
    .runtime-select {
      appearance: none;
      border: none;
      outline: none;
      background: transparent;
      color: var(--text-soft);
      font: inherit;
      font-size: 0.7rem;
      padding: 0 14px 0 0;
      background-image: linear-gradient(45deg, transparent 50%, currentColor 50%), linear-gradient(135deg, currentColor 50%, transparent 50%);
      background-position: calc(100% - 7px) 55%, calc(100% - 3px) 55%;
      background-size: 4px 4px, 4px 4px;
      background-repeat: no-repeat;
    }
    .composer-status {
      min-width: 120px;
      flex: 1;
      color: var(--text-faint);
      font-size: 0.68rem;
      text-align: right;
      white-space: nowrap;
      overflow: hidden;
      text-overflow: ellipsis;
    }

    .composer-queue {
      width: min(860px, 100%);
      max-width: 860px;
      margin: 0 auto 6px;
      display: grid;
      gap: 5px;
    }
    .queue-row {
      display: grid;
      grid-template-columns: minmax(0, 1fr) auto;
      gap: 8px;
      align-items: center;
      border: 1px solid var(--border);
      background: var(--surface);
      border-radius: 8px;
      padding: 7px 8px 7px 10px;
      box-shadow: var(--shadow-sm);
    }
    .queue-copy {
      min-width: 0;
      display: grid;
      gap: 2px;
    }
    .queue-label {
      color: var(--text-muted);
      font-size: 0.68rem;
      font-weight: 700;
      text-transform: uppercase;
      letter-spacing: 0;
    }
    .queue-text {
      color: var(--text-soft);
      font-size: 0.78rem;
      white-space: nowrap;
      overflow: hidden;
      text-overflow: ellipsis;
    }
    .queue-actions {
      display: flex;
      align-items: center;
      gap: 4px;
    }
    .queue-action {
      border: 1px solid var(--border);
      background: var(--surface-sunk);
      color: var(--text-muted);
      border-radius: 8px;
      height: 26px;
      padding: 0 8px;
      font-size: 0.7rem;
      font-weight: 650;
      cursor: pointer;
    }
    .queue-action:hover {
      color: var(--text);
      border-color: var(--border-strong);
    }

    .attachment-tray {
      width: min(860px, 100%);
      max-width: 860px;
      margin: 0 auto 6px;
      display: flex;
      align-items: center;
      gap: 6px;
      overflow-x: auto;
      padding-bottom: 1px;
    }
    .attachment-chip {
      min-width: 0;
      max-width: 210px;
      display: inline-flex;
      align-items: center;
      gap: 7px;
      border: 1px solid var(--border);
      background: color-mix(in srgb, var(--surface) 88%, transparent);
      border-radius: 10px;
      padding: 4px 5px 4px 4px;
      color: var(--text-soft);
      box-shadow: var(--shadow-sm);
    }
    .attachment-thumb {
      width: 28px;
      height: 28px;
      flex: 0 0 auto;
      border-radius: 7px;
      object-fit: cover;
      background: var(--surface-sunk);
      border: 1px solid var(--border);
    }
    .attachment-name {
      min-width: 0;
      overflow: hidden;
      white-space: nowrap;
      text-overflow: ellipsis;
      font-size: 0.72rem;
      font-weight: 650;
    }
    .attachment-remove {
      width: 22px;
      height: 22px;
      flex: 0 0 auto;
      border: none;
      border-radius: 8px;
      background: var(--surface-sunk);
      color: var(--text-muted);
      cursor: pointer;
      display: grid;
      place-items: center;
    }
    .attachment-remove:hover {
      color: var(--text);
      background: var(--border);
    }

    .composer {
      position: relative;
      width: min(860px, 100%);
      max-width: 860px;
      margin: 0 auto;
      background: color-mix(in srgb, var(--surface) 84%, transparent);
      border: 1px solid color-mix(in srgb, var(--border-strong) 84%, transparent);
      border-radius: 20px;
      box-shadow: 0 10px 30px oklch(19% 0.012 92 / 0.08);
      display: grid;
      grid-template-columns: auto auto minmax(0, 1fr) auto;
      align-items: end;
      padding: 5px;
      gap: 4px;
      min-width: 0;
      transition: border-color 120ms ease, box-shadow 160ms ease;
    }
    .composer:focus-within {
      border-color: var(--border-strong);
      box-shadow: 0 0 0 3px oklch(48% 0.115 248 / 0.11), 0 12px 36px oklch(19% 0.012 92 / 0.11);
    }
    .composer textarea {
      resize: none;
      border: none;
      outline: none;
      padding: 7px 7px;
      font-family: inherit;
      font-size: 0.94rem;
      line-height: 1.35;
      background: transparent;
      color: var(--text);
      max-height: 200px;
      min-height: 24px;
      min-width: 0;
      width: 100%;
    }
    :root[data-native-companion="true"] .composer textarea {
      font-size: 16px;
    }
    .composer textarea::placeholder { color: var(--text-faint); }

    .attachment-button, .mic-button, .send-button {
      width: 34px; height: 34px;
      border-radius: 13px;
      border: none;
      display: grid;
      place-items: center;
      cursor: pointer;
      transition: transform 120ms ease, background 120ms ease, color 120ms ease, box-shadow 160ms ease;
      position: relative;
    }
    .mic-button {
      background: var(--surface-sunk);
      color: var(--text-soft);
    }
    .attachment-button {
      background: transparent;
      color: var(--text-muted);
    }
    .attachment-button:hover { background: var(--surface-sunk); color: var(--text); }
    .mic-button:hover { background: var(--border); color: var(--text); }
    .mic-button[data-recording="true"] {
      background: var(--danger);
      color: var(--on-solid);
      animation: mic-pulse 1.2s ease-in-out infinite;
    }
    @keyframes mic-pulse {
      0%, 100% { box-shadow: 0 0 0 0 rgba(220, 38, 38, 0.45); }
      50% { box-shadow: 0 0 0 10px rgba(220, 38, 38, 0); }
    }
    .mic-timer {
      position: absolute;
      top: -20px; left: 50%;
      transform: translateX(-50%);
      font-size: 0.68rem;
      font-family: var(--mono);
      color: var(--danger);
      background: var(--surface);
      padding: 1px 6px;
      border-radius: 8px;
      border: 1px solid var(--danger);
    }
    .send-button {
      background: var(--text);
      color: var(--canvas);
      box-shadow: none;
    }
    .send-button:hover { filter: brightness(1.04); }
    .send-button:disabled { opacity: 0.4; cursor: not-allowed; box-shadow: none; }
    .send-button:active { transform: scale(0.95); }

    .composer-hint {
      width: min(860px, 100%);
      max-width: 860px;
      max-height: 0;
      margin: 0 auto;
      text-align: center;
      font-size: 0.66rem;
      color: var(--text-faint);
      overflow: hidden;
      text-overflow: ellipsis;
      white-space: nowrap;
      opacity: 0;
      transition: opacity 140ms ease, max-height 140ms ease, margin-top 140ms ease;
    }
    .composer-dock:focus-within .composer-hint {
      max-height: 18px;
      margin-top: 4px;
      opacity: 1;
    }

    /* Suggestion popup (slash / @) */
    .suggestion-popup {
      position: absolute;
      bottom: calc(100% + 6px);
      left: 12px; right: 12px;
      max-width: 940px;
      margin: 0 auto;
      background: var(--surface);
      border: 1px solid var(--border-strong);
      border-radius: 12px;
      box-shadow: var(--shadow-lg);
      padding: 4px;
      z-index: 40;
      max-height: 220px;
      overflow-y: auto;
      animation: pop-in 140ms ease-out;
    }
    .suggestion-header {
      font-size: 0.64rem;
      color: var(--text-muted);
      padding: 6px 8px 3px;
      text-transform: uppercase;
      letter-spacing: 0;
      font-weight: 600;
    }
    .suggestion-list { display: grid; gap: 2px; }
    .suggestion-item {
      display: grid;
      grid-template-columns: 24px minmax(0, 1fr) auto;
      align-items: center;
      gap: 7px;
      padding: 6px 8px;
      border-radius: 8px;
      cursor: pointer;
      border: none;
      background: transparent;
      text-align: left;
      color: var(--text-soft);
      font-size: 0.8rem;
    }
    .suggestion-item:hover,
    .suggestion-item[data-active="true"] {
      background: var(--accent-soft);
      color: var(--text);
    }
    .suggestion-icon {
      display: grid; place-items: center;
      font-family: var(--mono);
      font-size: 0.88rem;
      color: var(--accent-strong);
      background: var(--surface-sunk);
      border-radius: 8px;
      width: 24px; height: 24px;
      flex-shrink: 0;
    }
    .suggestion-main { display: grid; gap: 2px; min-width: 0; }
    .suggestion-title {
      font-weight: 600; color: var(--text);
      white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
    }
    .suggestion-subtitle {
      font-size: 0.68rem; color: var(--text-muted);
      white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
      font-family: var(--mono);
    }
    .suggestion-shortcut {
      font-size: 0.64rem;
      color: var(--text-faint);
    }

    /* Voice overlay (recording) */
    .voice-overlay {
      position: absolute;
      bottom: calc(100% + 6px);
      left: 12px; right: 12px;
      max-width: 940px;
      margin: 0 auto;
      pointer-events: none;
    }
    .voice-overlay-panel {
      background: var(--surface);
      border: 1px solid var(--danger);
      border-radius: 14px;
      padding: 10px 12px;
      box-shadow: var(--shadow-lg);
      display: grid;
      gap: 6px;
      animation: pop-in 180ms ease-out;
    }
    #voice-canvas {
      width: 100%;
      height: 46px;
      display: block;
    }
    .voice-overlay-meta {
      display: flex;
      justify-content: space-between;
      align-items: center;
      font-size: 0.68rem;
      color: var(--text-muted);
      font-family: var(--mono);
    }
    .voice-timer { color: var(--danger); font-weight: 600; }
    .voice-hint { text-align: right; flex: 1; }
    .voice-overlay[data-cancel="true"] .voice-overlay-panel { border-color: var(--warning); }
    .voice-overlay[data-cancel="true"] .voice-hint { color: var(--warning); }

    .voice-processing {
      width: min(940px, 100%);
      max-width: 940px;
      margin: 0 auto 6px;
      padding: 7px 10px;
      display: flex;
      align-items: center;
      justify-content: center;
      gap: 8px;
      min-height: 28px;
      background: var(--surface);
      border: 1px solid var(--accent-soft);
      border-radius: 12px;
      box-shadow: 0 4px 14px rgba(15, 23, 42, 0.08);
      color: var(--accent-strong);
      font-size: 0.74rem;
      font-weight: 600;
      animation: pop-in 140ms ease-out;
    }
    .voice-processing[hidden] { display: none; }
    .voice-processing-spinner {
      width: 15px;
      height: 15px;
      border-radius: 999px;
      border: 2px solid color-mix(in srgb, var(--accent) 22%, transparent);
      border-top-color: var(--accent);
      animation: voice-processing-spin 760ms linear infinite;
      flex: 0 0 auto;
    }
    .mic-button[data-processing="true"] {
      opacity: 0.62;
      cursor: wait;
      pointer-events: none;
    }
    @keyframes voice-processing-spin {
      to { transform: rotate(360deg); }
    }

    /* Command palette */
    .palette {
      position: fixed;
      inset: 0;
      z-index: 2000;
      display: grid;
      place-items: start center;
      padding-top: 14vh;
    }
    .palette-backdrop {
      position: absolute; inset: 0;
      background: oklch(19% 0.012 92 / 0.32);
      animation: fade-in 160ms ease-out;
    }
    .palette-panel {
      position: relative;
      width: min(620px, calc(100vw - 32px));
      background: var(--surface);
      border: 1px solid var(--border-strong);
      border-radius: 14px;
      box-shadow: var(--shadow-palette);
      overflow: hidden;
      display: grid;
      grid-template-rows: auto minmax(0, 1fr) auto;
      max-height: min(540px, calc(100vh - 28vh));
      animation: pop-in 160ms ease-out;
    }
    .palette-search {
      display: flex;
      align-items: center;
      gap: 10px;
      padding: 12px 14px;
      border-bottom: 1px solid var(--border);
      color: var(--text-muted);
    }
    .palette-search input {
      flex: 1;
      background: transparent;
      border: none;
      outline: none;
      font-size: 0.98rem;
      color: var(--text);
      font-family: inherit;
    }
    .palette-results {
      overflow-y: auto;
      padding: 6px;
    }
    .palette-group-label {
      font-size: 0.68rem;
      text-transform: uppercase;
      letter-spacing: 0;
      color: var(--text-faint);
      padding: 10px 12px 4px;
      font-weight: 600;
    }
    .palette-item {
      display: grid;
      grid-template-columns: 28px minmax(0, 1fr) auto;
      align-items: center;
      gap: 10px;
      padding: 9px 12px;
      border-radius: 8px;
      cursor: pointer;
      border: none;
      background: transparent;
      text-align: left;
      color: var(--text-soft);
      font-size: 0.9rem;
    }
    .palette-item[data-active="true"],
    .palette-item:hover { background: var(--surface-hover); color: var(--text); }
    .palette-item-icon {
      width: 24px; height: 24px;
      display: grid; place-items: center;
      font-family: var(--mono);
      font-weight: 700;
      color: var(--text-muted);
      background: color-mix(in srgb, var(--surface-sunk) 64%, transparent);
      border-radius: 7px;
      font-size: 0.8rem;
    }
    .palette-item-main { display: grid; min-width: 0; }
    .palette-item-title {
      font-weight: 600; color: var(--text);
      white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
    }
    .palette-item-sub {
      font-size: 0.76rem; color: var(--text-muted);
      white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
    }
    .palette-footer {
      display: flex;
      justify-content: space-between;
      padding: 10px 14px;
      border-top: 1px solid var(--border);
      font-size: 0.74rem;
      color: var(--text-faint);
    }
    .palette-footer kbd {
      margin: 0 2px;
      background: var(--surface-sunk);
      border-color: var(--border);
      color: var(--text-muted);
    }

    /* Toast */
    .toast-stack {
      position: fixed;
      bottom: 14px;
      right: 14px;
      display: grid;
      gap: 8px;
      z-index: 2500;
      max-width: calc(100vw - 24px);
      pointer-events: none;
    }
    .toast {
      background: var(--surface);
      border: 1px solid var(--border-strong);
      color: var(--text);
      box-shadow: var(--shadow-sm);
      padding: 8px 10px;
      border-radius: 9px;
      font-size: 0.82rem;
      display: flex;
      align-items: center;
      gap: 10px;
      pointer-events: auto;
      animation: toast-in 220ms ease-out;
      max-width: 420px;
    }
    .toast[data-kind="error"] { border-color: var(--danger); color: var(--danger); }
    .toast[data-kind="success"] { border-color: var(--success); color: var(--success); }
    .toast[data-kind="info"] { border-color: var(--accent); color: var(--accent-strong); }
    .toast button {
      background: transparent;
      border: none;
      color: inherit;
      cursor: pointer;
      text-decoration: underline;
      font-size: 0.82rem;
    }

    @keyframes toast-in {
      from { opacity: 0; transform: translateY(8px); }
      to { opacity: 1; transform: translateY(0); }
    }

    /* Skeleton loaders */
    .skeleton-wrap {
      display: grid;
      gap: 9px;
      padding: 12px 0;
    }
    .skeleton {
      background: linear-gradient(90deg,
        color-mix(in srgb, var(--surface-sunk) 68%, transparent) 0%,
        color-mix(in srgb, var(--surface-hover) 72%, transparent) 40%,
        color-mix(in srgb, var(--surface-sunk) 68%, transparent) 80%);
      background-size: 200% 100%;
      animation: skeleton-shimmer 1.4s ease-in-out infinite;
      border-radius: 6px;
    }
    .skeleton-line { height: 8px; }
    .skeleton-block { height: 58px; }
    .skeleton-avatar { width: 28px; height: 28px; border-radius: 8px; }

    @keyframes skeleton-shimmer {
      0% { background-position: 200% 0; }
      100% { background-position: -200% 0; }
    }

    /* Error */
    .stage-error {
      max-width: 540px;
      margin: 80px auto;
      padding: 20px 22px;
      background: var(--surface);
      border: 1px solid var(--danger);
      border-radius: var(--radius-lg);
      color: var(--danger);
      display: grid;
      gap: 8px;
    }
    .stage-error strong { color: var(--danger); font-size: 1rem; }

    /* Session menu (inline popover) */
    .menu-popover {
      position: fixed;
      z-index: 1800;
      background: var(--surface);
      border: 1px solid var(--border-strong);
      border-radius: 12px;
      box-shadow: var(--shadow-lg);
      min-width: 180px;
      padding: 4px;
      animation: pop-in 140ms ease-out;
    }
    .menu-item {
      display: flex;
      align-items: center;
      gap: 8px;
      padding: 8px 10px;
      background: transparent;
      border: none;
      width: 100%;
      text-align: left;
      cursor: pointer;
      border-radius: 8px;
      color: var(--text-soft);
      font-size: 0.9rem;
    }
    .menu-item:hover { background: var(--surface-hover); color: var(--text); }
    .menu-item[data-kind="danger"] { color: var(--danger); }
    .menu-item[data-kind="danger"]:hover { background: var(--danger-soft); }

    /* Animations & responsive */
    @keyframes fade-in {
      from { opacity: 0; transform: translateY(6px); }
      to { opacity: 1; transform: translateY(0); }
    }
    @keyframes pop-in {
      from { opacity: 0; transform: translateY(4px) scale(0.98); }
      to { opacity: 1; transform: translateY(0) scale(1); }
    }

    @media (prefers-reduced-motion: reduce) {
      *, *::before, *::after {
        animation-duration: 0.01ms !important;
        animation-iteration-count: 1 !important;
        transition-duration: 0.01ms !important;
        scroll-behavior: auto !important;
      }
    }

    @media (max-width: 900px) {
      #app { grid-template-columns: 1fr; }
      .drawer {
        position: fixed;
        inset: 0;
        z-index: 900;
        pointer-events: none;
      }
      .drawer-backdrop {
        display: block;
        position: absolute;
        inset: 0;
        background: rgba(15, 23, 42, 0.38);
        opacity: 0;
        transition: opacity 180ms ease;
        pointer-events: none;
      }
      .drawer-panel {
        position: absolute;
        top: 0; bottom: 0;
        left: 0;
        width: min(292px, 84vw);
        transform: translateX(-110%);
        transition: transform 240ms cubic-bezier(0.4, 0, 0.2, 1);
        box-shadow: var(--shadow-lg);
        pointer-events: auto;
        border-right: 1px solid var(--border-strong);
      }
      .workspace-chips {
        max-height: clamp(104px, 26dvh, 204px);
      }
      .icon-button.drawer-close { display: grid; place-items: center; }
      .drawer[data-open="true"] { pointer-events: auto; }
      .drawer[data-open="true"] .drawer-backdrop { opacity: 1; pointer-events: auto; }
      .drawer[data-open="true"] .drawer-panel { transform: translateX(0); }
      #menu-button { display: grid; }
      .live-strip {
        width: calc(100% - 18px);
        margin-top: 5px;
        grid-template-columns: minmax(0, 1fr);
        gap: 6px;
        padding: 6px 8px;
      }
      .live-metrics {
        overflow-x: auto;
        scrollbar-width: none;
      }
      .live-metrics::-webkit-scrollbar { display: none; }
      .live-detail { white-space: normal; display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; }
      .chat-stream { padding: 8px 10px 102px; scroll-padding-block-end: 102px; }
      .stage-inner { gap: 8px; }
      .topbar {
        width: calc(100% - 16px);
        margin-top: 7px;
        padding: 5px 6px;
        border-radius: 16px;
      }
      :root[data-native-companion="true"] .topbar {
        width: calc(100% - 18px);
        margin-top: calc(5px + env(safe-area-inset-top));
        top: env(safe-area-inset-top);
      }
      .topbar-subtitle { display: none; }
      .topbar-actions { gap: 4px; }
      .composer-dock { padding-left: 8px; padding-right: 8px; padding-top: 5px; }
      :root[data-native-companion="true"] .composer-dock { padding-bottom: 4px; }
      :root[data-native-companion="true"] .chat-stream { padding-bottom: 84px; scroll-padding-block-end: 84px; }
      .runtime-bar { margin-bottom: 4px; }
      .composer-status { display: none; }
      .runtime-pill,
      .runtime-icon-pill,
      .runtime-select-label,
      .runtime-access {
        min-height: 24px;
        padding: 3px 7px;
        font-size: 0.69rem;
      }
      .composer {
        border-radius: 18px;
        padding: 5px;
      }
      .attachment-button, .mic-button, .send-button {
        width: 33px;
        height: 33px;
        border-radius: 12px;
      }
      .composer textarea {
        padding-top: 7px;
        padding-bottom: 7px;
      }
      :root[data-native-companion="true"] .composer textarea { font-size: 16px; }
      .user-bubble { max-width: calc(100vw - 32px); }
      .assistant-block { padding: 9px 10px; }
      .empty-state { margin-top: 18px; }
      .suggestion-grid { grid-template-columns: 1fr; }
      .palette { padding: 10vh 12px 0; }
      .palette-panel { width: 100%; }
    }
    """#

    static let appJavaScript = #"""
    const API_BASE = "";
    const APP_VERSION = "v55";
    const STORAGE = {
      session: "miwhisper-companion.selectedSession",
      workspace: "miwhisper-companion.selectedWorkspace",
      draftPrefix: "miwhisper-companion.draft:",
      pinnedSessions: "miwhisper-companion.pinnedSessions",
      archivedSessions: "miwhisper-companion.archivedSessions",
      retryQueue: "miwhisper-companion.retryQueue",
      followupQueue: "miwhisper-companion.followupQueue",
      runtimePrefs: "miwhisper-companion.runtimePrefs",
      theme: "miwhisper-companion.theme",
      reasoningExpanded: "miwhisper-companion.reasoningExpanded",
      disclosureState: "miwhisper-companion.disclosureState",
    };

    const IS_TOUCH = matchMedia("(hover: none) and (pointer: coarse)").matches;
    const IS_MAC = /Mac|iPhone|iPad|iPod/.test(navigator.platform || "");
    const PREFERS_REDUCED_MOTION = matchMedia("(prefers-reduced-motion: reduce)").matches;
    const HAS_VIBRATE = typeof navigator.vibrate === "function";

    const els = {};

    const state = {
      workspaces: [],
      sessions: [],
      selectedSessionId: null,
      selectedWorkspaceId: null,
      sessionDetail: null,
      stageError: null,
      loading: false,
      pinned: new Set(loadJSON(STORAGE.pinnedSessions, [])),
      archived: new Set(loadJSON(STORAGE.archivedSessions, [])),
      expandedReasoning: new Set(loadJSON(STORAGE.reasoningExpanded, [])),
      pinnedToBottom: true,
      drawerOpen: false,
      recordStartedAt: null,
      recordTimerHandle: null,
      recording: false,
      recordingCancel: false,
      recordingTouchStartX: 0,
      mediaStream: null,
      mediaRecorder: null,
      audioContext: null,
      audioAnalyser: null,
      audioSource: null,
      audioProcessor: null,
      audioRaf: null,
      recordingMode: "media",
      recordedChunks: [],
      pcmChunks: [],
      pcmInputSampleRate: 0,
      recordedMimeType: "",
      recordedExtension: "m4a",
      voiceProcessing: false,
      voiceProcessingTimer: null,
      attachments: [],
      subagentsMode: false,
      sseController: null,
      sseActiveSessionId: null,
      sessionsSseController: null,
      sessionsStreamWorkspaceId: null,
      pollingHandle: null,
      pollingTickMs: 1100,
      suggestionKind: null,
      suggestionItems: [],
      suggestionActiveIndex: -1,
      suggestionAnchor: null,
      paletteItems: [],
      paletteActiveIndex: 0,
      paletteFiltered: [],
      sessionMenuOpenFor: null,
      connection: { state: "ok", lastError: null },
      lastBridgeContactAt: Date.now(),
      lastActivitySeen: 0,
      unseenAssistantCount: 0,
      titleOriginal: document.title,
      deferredInstallPrompt: null,
      retryQueue: loadJSON(STORAGE.retryQueue, []),
      followupQueue: loadJSON(STORAGE.followupQueue, []),
      queueDrainInFlight: false,
      runtimePrefs: normalizeRuntimePrefs(loadJSON(STORAGE.runtimePrefs, {})),
      disclosureState: loadJSON(STORAGE.disclosureState, {}),
      streamLastEventAt: 0,
      streamWatchdogHandle: null,
      streamRecoveryInFlight: false,
      sessionsRenderSignature: "",
      liveStripSignature: "",
      topbarSignature: "",
      stageRenderSignature: "",
      runtimeControlsSignature: "",
      carModeSignature: "",
      pendingStageRender: null,
      pendingTopbarRender: false,
      carMode: {
        lastSpokenFinalKey: null,
        lastSpokenAttentionKey: null,
        lastSpokenProgressKey: null,
        lastProgressSpokenAt: 0,
        busyStartedAt: 0,
        nativeWatchSessionId: null,
        nativeWatchVerbosity: null,
      },
      carCommand: {
        state: "off",
        message: "",
        transcript: "",
        promptPending: false,
        listeningRequested: false,
      },
      speech: {
        activeKey: null,
        utterance: null,
        audio: null,
        objectURL: null,
        provider: null,
        providerNoticeShown: false,
        chunks: [],
        chunkIndex: 0,
        paused: false,
        pending: false,
        manuallyStopped: false,
      },
    };

    const SLASH_COMMANDS = [
      { slug: "resume", label: "/resume", subtitle: "Resume la conversación en puntos clave", template: "Haz un resumen ejecutivo de esta conversación en 5 bullets máximo." },
      { slug: "plan", label: "/plan", subtitle: "Plan estructurado antes de implementar", template: "Antes de implementar nada, dame un plan paso a paso con los cambios que vas a hacer en qué archivos y el orden." },
      { slug: "debug", label: "/debug", subtitle: "Modo debug: investigar antes de cambiar", template: "Hay un bug. Antes de cambiar nada, investiga, explica la causa raíz y propón 2 opciones de fix con trade-offs." },
      { slug: "test", label: "/test", subtitle: "Añadir / correr tests", template: "Añade tests para los cambios recientes y asegúrate de que pasan. Muéstrame los tests y el output." },
      { slug: "review", label: "/review", subtitle: "Revisión de código", template: "Haz una revisión crítica del último patch que hiciste: busca bugs, edge cases, riesgos y mejoras de estilo." },
      { slug: "subagents", label: "/subagents", subtitle: "Armar modo subagentes para el próximo envío", action: "subagents" },
      { slug: "explain", label: "/explain", subtitle: "Explica un archivo o función", template: "Explícame de arriba abajo cómo funciona " },
      { slug: "stop", label: "/stop", subtitle: "Detener la sesión actual", action: "stop" },
      { slug: "new", label: "/new", subtitle: "Nueva sesión en este workspace", action: "new" },
      { slug: "focus", label: "/focus", subtitle: "Enfocar sesión en el Mac", action: "focus" },
      { slug: "clear", label: "/clear", subtitle: "Limpiar borrador", action: "clear" },
    ];

    init().catch((err) => showFatalError(err));

    async function init() {
      grabElements();
      const versionNode = document.getElementById("app-version");
      if (versionNode) versionNode.textContent = APP_VERSION;
      applyInitialTheme();
      renderConnection("ok");
      bindEvents();
      bindKeyboardShortcuts();
      bindVisibilityAndInstall();
      registerServiceWorker();
      bindVisualViewport();
      applyCarMode();
      renderRuntimeControls();
      renderCarModePanel();
      renderFollowupQueue();

      showStageSkeleton();
      showDrawerSkeleton();

      try {
        const bootstrap = await api("/api/bootstrap");
        state.workspaces = bootstrap.workspaces || [];
        const stored = localStorage.getItem(STORAGE.workspace);
        state.selectedWorkspaceId =
          stored && state.workspaces.some((w) => w.id === stored)
            ? stored
            : (state.workspaces.find((w) => w.isDefault) || state.workspaces[0])?.id || null;
        state.sessions = filterSessionsForSelectedWorkspace(bootstrap.sessions || []);

        const storedSession = localStorage.getItem(STORAGE.session);
        if (storedSession && findSession(storedSession)) {
          state.selectedSessionId = storedSession;
        } else {
          state.selectedSessionId = state.sessions[0]?.id || null;
        }

        renderWorkspaceChips();
        renderSessions();
        startSessionsStream();

        await refreshAll({ initial: true });
        loadComposerDraft();
        maybeDrainRetryQueue();
        handleLaunchIntent();
      } catch (err) {
        console.error("[miwhisper] bootstrap failed", err);
        renderConnection("error", "No puedo contactar con MiWhisper en 127.0.0.1:6009");
        showFatalError(err);
      }
    }

    function grabElements() {
      const ids = [
        "connection-banner", "connection-banner-text", "connection-banner-retry",
        "drawer", "menu-button", "new-session-button", "refresh-button", "bridge-status",
        "command-palette-button", "theme-toggle", "install-button", "footer-dot",
        "workspace-chips", "session-list", "session-title", "session-subtitle",
        "focus-button", "stop-button", "session-menu-button", "car-mode-toggle", "live-strip",
        "car-mode-panel", "car-mode-shell", "car-status-glyph", "car-status-label", "car-status-detail",
        "car-mode-title", "car-mode-summary", "car-voice-button", "car-voice-label", "car-arm-button", "car-arm-label", "car-repeat-button", "car-stop-audio-button",
        "chat-stream",
        "scroll-bottom", "scroll-bottom-badge", "composer", "composer-shell",
        "composer-hint", "attachment-button", "image-input", "attachment-tray", "voice-button", "send-button", "mic-timer",
        "runtime-bar", "plan-mode-toggle", "service-tier-select", "reasoning-select", "access-mode-toggle",
        "queue-mode-toggle", "notifications-toggle", "composer-status", "composer-queue",
        "voice-overlay", "voice-canvas", "voice-timer", "voice-hint",
        "voice-processing", "voice-processing-text",
        "suggestion-popup", "suggestion-header", "suggestion-list",
        "command-palette", "palette-input", "palette-results",
        "toast-stack", "composer-dock",
      ];
      for (const id of ids) {
        els[camelize(id)] = document.getElementById(id);
      }
      els.drawerBackdrops = document.querySelectorAll("[data-close-drawer]");
      els.carVerbosityButtons = document.querySelectorAll("[data-car-verbosity]");
      els.paletteBackdrop = document.querySelector("[data-close-palette]");
    }

    function camelize(id) {
      return id.replace(/-([a-z])/g, (_, ch) => ch.toUpperCase());
    }

    function applyInitialTheme() {
      const stored = localStorage.getItem(STORAGE.theme);
      const system = matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light";
      const theme = stored || system;
      document.documentElement.dataset.theme = theme;
      updateThemeColorMeta(theme);
      matchMedia("(prefers-color-scheme: dark)").addEventListener?.("change", (e) => {
        if (localStorage.getItem(STORAGE.theme)) return;
        const next = e.matches ? "dark" : "light";
        document.documentElement.dataset.theme = next;
        updateThemeColorMeta(next);
      });
    }

    function toggleTheme() {
      const current = document.documentElement.dataset.theme === "dark" ? "dark" : "light";
      const next = current === "dark" ? "light" : "dark";
      document.documentElement.dataset.theme = next;
      localStorage.setItem(STORAGE.theme, next);
      updateThemeColorMeta(next);
      vibrate(8);
    }

    function updateThemeColorMeta(theme) {
      const color = theme === "dark" ? "#0f0f0f" : "#f7f7f5";
      let meta = document.querySelector('meta[name="theme-color"]:not([media])');
      if (!meta) {
        meta = document.createElement("meta");
        meta.name = "theme-color";
        document.head.appendChild(meta);
      }
      meta.content = color;
    }

    function normalizeRuntimePrefs(raw) {
      const prefs = {
        planMode: false,
        serviceTier: "useConfigDefault",
        reasoningEffort: "useConfigDefault",
        accessMode: "fullAccess",
        queueMode: "steer",
        notifications: false,
        carMode: false,
        carArmed: false,
        carVerbosity: "brief",
      };
      if (raw && typeof raw === "object") {
        Object.assign(prefs, raw);
      }
      if (!["useConfigDefault", "fast", "flex"].includes(prefs.serviceTier)) prefs.serviceTier = "useConfigDefault";
      if (!["useConfigDefault", "low", "medium", "high", "intense"].includes(prefs.reasoningEffort)) prefs.reasoningEffort = "useConfigDefault";
      if (!["fullAccess", "onRequest"].includes(prefs.accessMode)) prefs.accessMode = "fullAccess";
      if (!["steer", "queue"].includes(prefs.queueMode)) prefs.queueMode = "steer";
      if (!["brief", "normal", "detail"].includes(prefs.carVerbosity)) prefs.carVerbosity = "brief";
      prefs.planMode = prefs.planMode === true;
      prefs.notifications = prefs.notifications === true;
      prefs.carMode = prefs.carMode === true;
      prefs.carArmed = prefs.carArmed === true;
      return prefs;
    }

    function saveRuntimePrefs() {
      try { localStorage.setItem(STORAGE.runtimePrefs, JSON.stringify(state.runtimePrefs)); } catch {}
    }

    function togglePlanMode() {
      state.runtimePrefs.planMode = !state.runtimePrefs.planMode;
      saveRuntimePrefs();
      renderRuntimeControls();
      vibrate(8);
    }

    function toggleQueueMode() {
      state.runtimePrefs.queueMode = state.runtimePrefs.queueMode === "queue" ? "steer" : "queue";
      saveRuntimePrefs();
      renderRuntimeControls();
      vibrate(8);
    }

    function toggleAccessMode() {
      state.runtimePrefs.accessMode = state.runtimePrefs.accessMode === "onRequest" ? "fullAccess" : "onRequest";
      saveRuntimePrefs();
      renderRuntimeControls();
      toast(state.runtimePrefs.accessMode === "onRequest" ? "On-Request para chats nuevos" : "Full Access para chats nuevos", "info", 1500);
      vibrate(8);
    }

    function toggleCarMode() {
      state.runtimePrefs.carMode = !state.runtimePrefs.carMode;
      if (!state.runtimePrefs.carMode) state.runtimePrefs.carArmed = false;
      saveRuntimePrefs();
      applyCarMode();
      syncNativeCarWatch(state.sessionDetail, { reason: "toggle-car-mode" });
      syncNativeCarCommandListening(state.sessionDetail, { reason: "toggle-car-mode" });
      renderRuntimeControls();
      renderCarModePanel();
      if (state.runtimePrefs.carMode) {
        toast("Modo coche activo: dictado, resumen y controles grandes", "success", 1800);
        if (state.drawerOpen) openDrawer(false);
      } else {
        toast("Modo coche desactivado", "info", 1200);
      }
      vibrate(12);
    }

    function toggleCarArmed() {
      if (!state.runtimePrefs.carMode) return;
      if (!nativeCarModeBridge()) {
        toast("Escucha armada requiere la app nativa de iOS", "warn", 2600);
        return;
      }
      state.runtimePrefs.carArmed = !state.runtimePrefs.carArmed;
      if (!state.runtimePrefs.carArmed) {
        state.carCommand = { state: "off", message: "", transcript: "", promptPending: false, listeningRequested: false };
      }
      saveRuntimePrefs();
      syncNativeCarCommandListening(state.sessionDetail, { reason: "toggle-car-armed" });
      renderCarModePanel();
      toast(state.runtimePrefs.carArmed ? "Modo coche armado: di oye Codex" : "Modo coche armado desactivado", "info", 1500);
      vibrate(12);
    }

    function setCarVerbosity(value) {
      if (!["brief", "normal", "detail"].includes(value)) return;
      state.runtimePrefs.carVerbosity = value;
      saveRuntimePrefs();
      state.carModeSignature = "";
      restartNativeCarWatch("car-verbosity");
      syncNativeCarWatch(state.sessionDetail, { reason: "car-verbosity" });
      renderCarModePanel();
      toast(`Resumen ${value === "brief" ? "breve" : value === "detail" ? "con detalle" : "normal"}`, "info", 1000);
      vibrate(8);
    }

    function applyCarMode() {
      const active = state.runtimePrefs.carMode === true;
      document.body.dataset.carMode = active ? "true" : "false";
      els.carModePanel.hidden = !active;
      if (els.carModeToggle) {
        els.carModeToggle.dataset.active = active ? "true" : "false";
        els.carModeToggle.setAttribute("aria-pressed", active ? "true" : "false");
        els.carModeToggle.title = active ? "Salir del modo coche" : "Modo coche";
      }
      if (active && state.runtimePrefs.queueMode !== "queue") {
        state.runtimePrefs.queueMode = "queue";
        saveRuntimePrefs();
      }
    }

    function runtimeCreateSessionParams() {
      const params = {};
      if (state.runtimePrefs.serviceTier && state.runtimePrefs.serviceTier !== "useConfigDefault") {
        params.serviceTier = state.runtimePrefs.serviceTier;
      }
      if (state.runtimePrefs.reasoningEffort && state.runtimePrefs.reasoningEffort !== "useConfigDefault") {
        params.reasoningEffort = state.runtimePrefs.reasoningEffort;
      }
      if (state.runtimePrefs.accessMode && state.runtimePrefs.accessMode !== "fullAccess") {
        params.accessMode = state.runtimePrefs.accessMode;
      }
      return params;
    }

    function runtimeTurnParams() {
      return runtimeCreateSessionParams();
    }

    function applyPlanMode(text) {
      if (!state.runtimePrefs.planMode) return text;
      return [
        "Plan mode: before making changes, inspect first, propose a concise implementation plan, and wait for confirmation unless the task is explicitly read-only.",
        "",
        text
      ].join("\n");
    }

    function applySubagentsMode(text) {
      if (!state.subagentsMode) return text;
      return [
        "Subagents mode: if subagents are available in this Codex environment, split the work into bounded parallel tasks, assign clear file/module ownership, use subagents only where they materially reduce wall-clock time, and integrate their results before final response. If subagents are not available, say so briefly and continue locally with the same decomposition.",
        "",
        text
      ].join("\n");
    }

    function renderRuntimeControls() {
      if (!els.planModeToggle) return;
      const busy = state.sessionDetail?.session?.isBusy === true;
      const activeSessionAccess = state.sessionDetail?.session?.accessMode;
      const mode = activeSessionAccess || state.runtimePrefs.accessMode || "fullAccess";
      const statusParts = [];
      if (busy) {
        statusParts.push(state.runtimePrefs.queueMode === "queue" ? "se encolara al terminar" : "interviene en la run activa");
      } else {
        statusParts.push(state.selectedSessionId ? "siguiente turno" : "nuevo chat");
      }
      if (state.runtimePrefs.serviceTier !== "useConfigDefault") statusParts.push(state.runtimePrefs.serviceTier);
      if (state.runtimePrefs.planMode) statusParts.push("plan");
      if (state.subagentsMode) statusParts.push("subagents");
      if (state.runtimePrefs.carMode) statusParts.push(`coche ${carVerbosityLabel(state.runtimePrefs.carVerbosity)}${state.runtimePrefs.carArmed ? " armado" : ""}`);
      if (mode === "onRequest") statusParts.push("on-request");
      if (state.runtimePrefs.reasoningEffort !== "useConfigDefault") statusParts.push(`think ${reasoningShortLabel(state.runtimePrefs.reasoningEffort)}`);
      const statusText = statusParts.join(" · ");
      const signature = [
        busy ? "busy" : "idle",
        state.runtimePrefs.planMode ? "plan" : "",
        state.runtimePrefs.serviceTier || "",
        state.runtimePrefs.reasoningEffort || "",
        state.runtimePrefs.queueMode || "",
        state.runtimePrefs.notifications ? "notif" : "",
        state.runtimePrefs.carMode ? "car" : "",
        state.runtimePrefs.carArmed ? "armed" : "",
        state.runtimePrefs.carVerbosity || "",
        state.subagentsMode ? "subagents" : "",
        state.attachments.length ? `att-${state.attachments.length}` : "",
        mode,
        statusText,
      ].join("|");
      if (signature === state.runtimeControlsSignature) return;
      state.runtimeControlsSignature = signature;
      els.planModeToggle.dataset.active = state.runtimePrefs.planMode ? "true" : "false";
      els.planModeToggle.setAttribute("aria-pressed", state.runtimePrefs.planMode ? "true" : "false");
      els.serviceTierSelect.value = state.runtimePrefs.serviceTier || "useConfigDefault";
      els.reasoningSelect.value = state.runtimePrefs.reasoningEffort || "useConfigDefault";
      if (els.accessModeToggle) {
        els.accessModeToggle.textContent = mode === "onRequest" ? "On-request" : "Full access";
        els.accessModeToggle.dataset.mode = mode;
        els.accessModeToggle.dataset.active = mode === "onRequest" ? "true" : "false";
        els.accessModeToggle.setAttribute("aria-pressed", mode === "onRequest" ? "true" : "false");
        els.accessModeToggle.title = activeSessionAccess
          ? "Modo de acceso de esta sesión"
          : "Cambiar Full Access / On-Request para el siguiente turno";
      }
      els.queueModeToggle.hidden = !busy;
      els.queueModeToggle.dataset.mode = state.runtimePrefs.queueMode;
      els.queueModeToggle.dataset.active = busy ? "true" : "false";
      els.queueModeToggle.textContent = state.runtimePrefs.queueMode === "queue" ? "Encolar" : "Intervenir";
      els.queueModeToggle.setAttribute("aria-pressed", state.runtimePrefs.queueMode === "queue" ? "true" : "false");
      els.notificationsToggle.dataset.active = state.runtimePrefs.notifications ? "true" : "false";
      els.notificationsToggle.setAttribute("aria-pressed", state.runtimePrefs.notifications ? "true" : "false");
      if (els.carModeToggle) {
        els.carModeToggle.dataset.active = state.runtimePrefs.carMode ? "true" : "false";
        els.carModeToggle.setAttribute("aria-pressed", state.runtimePrefs.carMode ? "true" : "false");
      }
      els.composerStatus.textContent = statusText;
      renderCarModePanel();
    }

    function reasoningShortLabel(value) {
      switch (value) {
      case "low": return "low";
      case "medium": return "med";
      case "high": return "high";
      case "intense": return "xhigh";
      default: return "default";
      }
    }

    function carVerbosityLabel(value) {
      if (value === "detail") return "detalle";
      if (value === "normal") return "normal";
      return "breve";
    }

    async function requestNotifications() {
      if (!("Notification" in window)) {
        toast("Este navegador no soporta notificaciones", "error");
        return;
      }
      if (Notification.permission === "granted") {
        state.runtimePrefs.notifications = !state.runtimePrefs.notifications;
        saveRuntimePrefs();
        renderRuntimeControls();
        toast(state.runtimePrefs.notifications ? "Avisos activados" : "Avisos pausados", "success");
        return;
      }
      if (Notification.permission === "denied") {
        state.runtimePrefs.notifications = false;
        saveRuntimePrefs();
        renderRuntimeControls();
        toast("Notificaciones bloqueadas en el navegador", "error");
        return;
      }
      const permission = await Notification.requestPermission();
      state.runtimePrefs.notifications = permission === "granted";
      saveRuntimePrefs();
      renderRuntimeControls();
      toast(state.runtimePrefs.notifications ? "Avisos activados" : "Avisos no activados", state.runtimePrefs.notifications ? "success" : "info");
    }

    function notifyIfUseful(title, body) {
      if (!state.runtimePrefs.notifications) return;
      if (!("Notification" in window) || Notification.permission !== "granted") return;
      if (!document.hidden && state.pinnedToBottom) return;
      try {
        const ready = navigator.serviceWorker && navigator.serviceWorker.ready;
        if (ready) {
          ready.then((registration) => registration.showNotification(title, {
            body,
            icon: "/app-icon.png",
            badge: "/app-icon.png",
            tag: "miwhisper-companion-session",
            renotify: false,
          }))
          .catch(() => new Notification(title, { body, icon: "/app-icon.png" }));
        } else {
          new Notification(title, { body, icon: "/app-icon.png" });
        }
      } catch {
        try { new Notification(title, { body, icon: "/app-icon.png" }); } catch {}
      }
    }

    function renderSpeechActionsHTML(key) {
      const isActive = state.speech.activeKey === key;
      const isPaused = isActive && state.speech.paused;
      const title = isActive ? (isPaused ? "Continuar lectura" : "Pausar lectura") : "Leer respuesta en voz alta";
      return `
        <div class="assistant-response-actions">
          <button class="speak-message" data-speak-action="toggle" type="button" title="${title}" aria-label="${title}">
            ${speakerIconSVG(isActive && !isPaused)}
          </button>
          <button class="speak-stop" data-speak-action="stop" type="button" title="Detener lectura" aria-label="Detener lectura"${isActive ? "" : " hidden"}>
            ${stopIconSVG()}
          </button>
        </div>
      `;
    }

    function handleSpeechActionClick(event) {
      const button = event.target.closest("[data-speak-action]");
      if (!button || !els.chatStream.contains(button)) return;
      const item = button.closest("[data-speak-key]");
      if (!item) return;
      event.preventDefault();
      event.stopPropagation();
      if (button.dataset.speakAction === "stop") {
        stopSpeech();
        return;
      }
      toggleSpeechForItem(item);
    }

    function handleSpeechShortcut(event) {
      if (event.target.closest("button, a, input, textarea, select, summary, details, pre, code")) return;
      const item = event.target.closest("[data-speak-key]");
      if (!item || !els.chatStream.contains(item)) return;
      event.preventDefault();
      toggleSpeechForItem(item);
    }

    function handleSpeechContextMenu(event) {
      const item = event.target.closest("[data-speak-key]");
      if (!item || !els.chatStream.contains(item)) return;
      event.preventDefault();
      toggleSpeechForItem(item);
    }

    function toggleSpeechForItem(item) {
      const key = item.dataset.speakKey;
      const text = item.dataset.speakText || "";
      if (!key || !text.trim()) return;
      if (state.speech.activeKey === key) {
        if (state.speech.paused) {
          resumeSpeech();
        } else {
          pauseSpeech();
        }
        return;
      }
      startSpeech(key, text);
    }

    async function startSpeech(key, text) {
      stopSpeech({ silent: true });
      const clean = normalizeSpeechText(text);
      if (!clean) {
        toast("No hay texto legible en esta respuesta", "warn");
        return;
      }
      const capped = clean.length > 6000 ? clean.slice(0, 6000).trimEnd() + ". Mensaje truncado para lectura." : clean;
      if (clean.length > 6000) toast("Respuesta larga: leo los primeros minutos", "info", 2200);
      state.speech.activeKey = key;
      state.speech.paused = false;
      state.speech.pending = true;
      state.speech.manuallyStopped = false;
      state.speech.provider = "browser";
      state.speech.audio = null;
      syncSpeechUI();

      if (nativeSpeechIsSupported()) {
        startNativeSpeech(key, capped);
        return;
      }
      startBrowserSpeech(key, capped);
    }

    function startNativeSpeech(key, text) {
      state.speech.activeKey = key;
      state.speech.chunks = [];
      state.speech.chunkIndex = 0;
      state.speech.paused = false;
      state.speech.pending = false;
      state.speech.manuallyStopped = false;
      state.speech.provider = "native";
      nativeSpeech().speak({
        key,
        text,
        lang: preferredSpeechLanguage(text),
        rate: 0.52,
        pitch: 1,
      });
      syncSpeechUI();
    }

    function startBrowserSpeech(key, text) {
      if (!speechIsSupported()) {
        toast("Este navegador no soporta lectura en voz alta", "error");
        clearSpeechState();
        return;
      }
      state.speech.activeKey = key;
      state.speech.chunks = splitSpeechText(text);
      state.speech.chunkIndex = 0;
      state.speech.paused = false;
      state.speech.pending = false;
      state.speech.manuallyStopped = false;
      state.speech.provider = "browser";
      if (!state.speech.providerNoticeShown) {
        state.speech.providerNoticeShown = true;
        toast("Voz web del navegador: puente nativo no detectado", "warn", 2600);
      }
      speakNextChunk();
    }

    function speakNextChunk() {
      if (!state.speech.activeKey || state.speech.manuallyStopped || state.speech.provider !== "browser") return;
      const chunk = state.speech.chunks[state.speech.chunkIndex];
      if (!chunk) {
        clearSpeechState();
        return;
      }
      const utterance = new SpeechSynthesisUtterance(chunk);
      utterance.lang = navigator.language || "es-ES";
      utterance.rate = 0.98;
      utterance.pitch = 1;
      utterance.onend = () => {
        if (state.speech.utterance !== utterance || state.speech.manuallyStopped) return;
        state.speech.chunkIndex += 1;
        speakNextChunk();
      };
      utterance.onerror = () => {
        if (state.speech.utterance !== utterance) return;
        if (!state.speech.manuallyStopped) toast("No se pudo continuar la lectura", "error");
        clearSpeechState();
      };
      state.speech.utterance = utterance;
      window.speechSynthesis.cancel();
      window.speechSynthesis.speak(utterance);
      syncSpeechUI();
    }

    function pauseSpeech() {
      if (!state.speech.activeKey) return;
      if (state.speech.provider === "native") {
        try { nativeSpeech()?.pause(); } catch {}
      } else {
        try { window.speechSynthesis.pause(); } catch {}
      }
      state.speech.paused = true;
      syncSpeechUI();
    }

    function resumeSpeech() {
      if (!state.speech.activeKey) return;
      if (state.speech.provider === "native") {
        try { nativeSpeech()?.resume(); } catch {}
      } else {
        try { window.speechSynthesis.resume(); } catch {}
      }
      state.speech.paused = false;
      syncSpeechUI();
    }

    function stopSpeech(options = {}) {
      if (!state.speech.activeKey && !state.speech.utterance && !state.speech.audio) return;
      state.speech.manuallyStopped = true;
      if (state.speech.provider === "native") {
        try { nativeSpeech()?.stop(); } catch {}
      }
      try { window.speechSynthesis?.cancel(); } catch {}
      try {
        if (state.speech.audio) {
          state.speech.audio.pause();
          state.speech.audio.removeAttribute("src");
          state.speech.audio.load();
        }
      } catch {}
      clearSpeechState();
      if (!options.silent) toast("Lectura detenida", "info", 1200);
    }

    function clearSpeechState() {
      if (state.speech.objectURL) {
        try { URL.revokeObjectURL(state.speech.objectURL); } catch {}
      }
      if (state.speech.audio?.parentNode) {
        try { state.speech.audio.parentNode.removeChild(state.speech.audio); } catch {}
      }
      state.speech.activeKey = null;
      state.speech.utterance = null;
      state.speech.audio = null;
      state.speech.objectURL = null;
      state.speech.provider = null;
      state.speech.chunks = [];
      state.speech.chunkIndex = 0;
      state.speech.paused = false;
      state.speech.pending = false;
      state.speech.manuallyStopped = false;
      syncSpeechUI();
    }

    function syncSpeechUI() {
      document.querySelectorAll("[data-speak-key]").forEach((item) => {
        const isActive = state.speech.activeKey === item.dataset.speakKey;
        const isPaused = isActive && state.speech.paused;
        item.classList.toggle("is-speaking", isActive);
        item.classList.toggle("is-paused", isPaused);
        const toggle = item.querySelector("[data-speak-action='toggle']");
        const stop = item.querySelector("[data-speak-action='stop']");
        if (toggle) {
          const title = isActive
            ? (state.speech.pending ? "Preparando voz local" : (isPaused ? "Continuar lectura" : "Pausar lectura"))
            : "Leer respuesta en voz alta";
          toggle.title = title;
          toggle.setAttribute("aria-label", title);
          toggle.innerHTML = speakerIconSVG(isActive && !isPaused);
        }
        if (stop) stop.hidden = !isActive;
      });
      renderCarModePanel();
      syncNativeCarCommandListening(state.sessionDetail, { reason: "speech-ui" });
    }

    function speechTextForEntry(entry) {
      if (!entry || entry.blockKind !== "final") return "";
      return normalizeSpeechText(entry.detail || "");
    }

    function normalizeSpeechText(text) {
      return String(text || "")
        .replace(/```[\s\S]*?```/g, " Bloque de código omitido. ")
        .replace(/`([^`]+)`/g, "$1")
        .replace(/!\[([^\]]*)\]\([^)]+\)/g, "$1")
        .replace(/\[([^\]]+)\]\([^)]+\)/g, "$1")
        .replace(/^#{1,6}\s+/gm, "")
        .replace(/^>\s?/gm, "")
        .replace(/^\s*[-*+]\s+/gm, "")
        .replace(/^\s*\d+\.\s+/gm, "")
        .replace(/[*_~#>|]/g, "")
        .replace(/\n{3,}/g, "\n\n")
        .replace(/[ \t]{2,}/g, " ")
        .trim();
    }

    function splitSpeechText(text) {
      const chunks = [];
      const source = String(text || "").replace(/\s+/g, " ").trim();
      let remaining = source;
      while (remaining.length > 850) {
        const slice = remaining.slice(0, 850);
        const boundary = Math.max(
          slice.lastIndexOf(". "),
          slice.lastIndexOf("? "),
          slice.lastIndexOf("! "),
          slice.lastIndexOf("; "),
          slice.lastIndexOf(", ")
        );
        const cut = boundary > 260 ? boundary + 1 : 850;
        chunks.push(remaining.slice(0, cut).trim());
        remaining = remaining.slice(cut).trim();
      }
      if (remaining) chunks.push(remaining);
      return chunks;
    }

    function speechIsSupported() {
      return "speechSynthesis" in window && "SpeechSynthesisUtterance" in window;
    }

    function nativeSpeech() {
      return window.miwhisperNativeSpeech || null;
    }

    function nativeSpeechIsSupported() {
      return !!nativeSpeech()?.isAvailable;
    }

    function preferredSpeechLanguage(text) {
      const source = String(text || "").toLowerCase();
      if (/[áéíóúñ¿¡]/i.test(source)) return "es-ES";
      const spanishHints = [" el ", " la ", " los ", " las ", " que ", " para ", " con ", " una ", " estoy ", " necesito ", " terminado "];
      if (spanishHints.some((hint) => source.includes(hint))) return "es-ES";
      const language = navigator.language || "es-ES";
      return language.toLowerCase().startsWith("es") ? "es-ES" : language;
    }

    function handleNativeSpeechEvent(event) {
      const detail = event?.detail || {};
      if (state.speech.provider !== "native") return;
      if (detail.key && state.speech.activeKey && detail.key !== state.speech.activeKey) return;
      switch (detail.type) {
        case "start":
        case "resume":
          state.speech.paused = false;
          state.speech.pending = false;
          if (detail.type === "start" && !state.speech.providerNoticeShown) {
            state.speech.providerNoticeShown = true;
            const voice = [detail.voiceName, detail.voiceQuality].filter(Boolean).join(" · ");
            toast(voice ? `Voz nativa iOS: ${voice}` : "Voz nativa iOS activa", "success", 3000);
          }
          syncSpeechUI();
          break;
        case "pause":
          state.speech.paused = true;
          syncSpeechUI();
          break;
        case "end":
        case "stop":
          clearSpeechState();
          break;
        case "error":
          toast(detail.message || "No se pudo leer con la voz nativa", "error");
          clearSpeechState();
          break;
      }
    }

    function speakerIconSVG(active) {
      return active
        ? `<svg viewBox="0 0 24 24" aria-hidden="true"><path fill="currentColor" d="M3 9v6h4l5 4V5L7 9zm13.5 3a4.5 4.5 0 0 0-2.5-4v8a4.5 4.5 0 0 0 2.5-4m-2.5-8.2v2.1a7 7 0 0 1 0 12.2v2.1a9 9 0 0 0 0-16.4"/></svg>`
        : `<svg viewBox="0 0 24 24" aria-hidden="true"><path fill="currentColor" d="M3 9v6h4l5 4V5L7 9zm13 3a4 4 0 0 0-2-3.5v7A4 4 0 0 0 16 12"/></svg>`;
    }

    function stopIconSVG() {
      return `<svg viewBox="0 0 24 24" aria-hidden="true"><path fill="currentColor" d="M7 7h10v10H7z"/></svg>`;
    }

    function bindEvents() {
      els.menuButton.addEventListener("click", () => openDrawer(true));
      els.drawerBackdrops.forEach((el) => el.addEventListener("click", () => openDrawer(false)));
      els.refreshButton.addEventListener("click", () => refreshAll());
      els.newSessionButton.addEventListener("click", () => startNewSession());
      els.commandPaletteButton.addEventListener("click", () => openPalette());
      els.themeToggle.addEventListener("click", toggleTheme);
      els.installButton.addEventListener("click", handleInstallClick);
      els.connectionBannerRetry.addEventListener("click", () => refreshAll());
      els.planModeToggle.addEventListener("click", togglePlanMode);
      els.serviceTierSelect.addEventListener("change", () => {
        state.runtimePrefs.serviceTier = els.serviceTierSelect.value;
        saveRuntimePrefs();
        renderRuntimeControls();
      });
      els.reasoningSelect.addEventListener("change", () => {
        state.runtimePrefs.reasoningEffort = els.reasoningSelect.value;
        saveRuntimePrefs();
        renderRuntimeControls();
      });
      els.accessModeToggle.addEventListener("click", toggleAccessMode);
      els.queueModeToggle.addEventListener("click", toggleQueueMode);
      els.notificationsToggle.addEventListener("click", requestNotifications);
      els.carModeToggle.addEventListener("click", toggleCarMode);
      els.carVoiceButton.addEventListener("click", () => toggleRecording());
      els.carArmButton.addEventListener("click", toggleCarArmed);
      els.carRepeatButton.addEventListener("click", () => speakCarSummary({ force: true }));
      els.carStopAudioButton.addEventListener("click", handleCarStop);
      els.carVerbosityButtons.forEach((button) => {
        button.addEventListener("click", () => setCarVerbosity(button.dataset.carVerbosity));
      });
      els.attachmentButton.addEventListener("click", () => els.imageInput.click());
      els.imageInput.addEventListener("change", () => {
        handleImageFiles(els.imageInput.files);
        els.imageInput.value = "";
      });

      els.sessionTitle.addEventListener("dblclick", () => startRenameInline(state.selectedSessionId));
      els.sessionMenuButton.addEventListener("click", (e) => openSessionMenu(state.selectedSessionId, e.currentTarget));
      els.focusButton.addEventListener("click", () => focusSession(state.selectedSessionId));
      els.stopButton.addEventListener("click", () => stopSession(state.selectedSessionId));

      els.composer.addEventListener("keydown", handleComposerKey);
      els.composer.addEventListener("input", () => {
        autoGrow();
        saveDraft(state.selectedSessionId, els.composer.value);
        maybeShowSuggestions();
      });
      els.composer.addEventListener("blur", () => setTimeout(() => hideSuggestions(), 100));
      els.composer.addEventListener("focus", maybeShowSuggestions);
      els.sendButton.addEventListener("click", sendComposer);

      if (IS_TOUCH) {
        els.voiceButton.addEventListener("touchstart", handleVoiceTouchStart, { passive: false });
        els.voiceButton.addEventListener("touchmove", handleVoiceTouchMove, { passive: false });
        els.voiceButton.addEventListener("touchend", handleVoiceTouchEnd);
        els.voiceButton.addEventListener("touchcancel", handleVoiceTouchEnd);
      } else {
        els.voiceButton.addEventListener("click", toggleRecording);
      }

      els.chatStream.addEventListener("scroll", handleStreamScroll, { passive: true });
      els.chatStream.addEventListener("click", handleSpeechActionClick);
      els.chatStream.addEventListener("dblclick", handleSpeechShortcut);
      els.chatStream.addEventListener("contextmenu", handleSpeechContextMenu);
      els.scrollBottom.addEventListener("click", () => {
        state.pinnedToBottom = true;
        state.unseenAssistantCount = 0;
        updateScrollBottomButton();
        scrollToBottom("smooth");
      });

      els.paletteInput.addEventListener("input", filterPalette);
      els.paletteInput.addEventListener("keydown", handlePaletteKey);
      els.paletteBackdrop?.addEventListener("click", closePalette);

      document.addEventListener("click", closeAnyOpenMenus);
      window.addEventListener("online", () => {
        renderConnection("ok", "Conectado");
        recoverSelectedSessionConnection("online", { restartStream: true, silent: true });
      });
      window.addEventListener("offline", () => renderConnection("error", "Sin conexión"));
      window.addEventListener("miwhisper-native-speech", handleNativeSpeechEvent);
      window.addEventListener("miwhisper-native-car-command", handleNativeCarCommandEvent);
    }

    function bindKeyboardShortcuts() {
      document.addEventListener("keydown", (e) => {
        const mod = IS_MAC ? e.metaKey : e.ctrlKey;
        if (mod && e.key.toLowerCase() === "k") {
          e.preventDefault();
          togglePalette();
          return;
        }
        if (mod && e.shiftKey && e.key.toLowerCase() === "n") {
          e.preventDefault();
          startNewSession();
          return;
        }
        if (mod && e.key === "/") {
          e.preventDefault();
          els.composer.focus();
          return;
        }
        if (e.key === "Escape") {
          if (!els.commandPalette.hidden) { closePalette(); return; }
          if (!els.suggestionPopup.hidden) { hideSuggestions(); return; }
          if (state.drawerOpen) { openDrawer(false); return; }
        }
      });
    }

    function bindVisibilityAndInstall() {
      document.addEventListener("visibilitychange", () => {
        syncNativeCarWatch(state.sessionDetail, { reason: document.hidden ? "hidden" : "visible" });
        syncNativeCarCommandListening(state.sessionDetail, { reason: document.hidden ? "hidden" : "visible" });
        if (!document.hidden) {
          resetTitle();
          state.unseenAssistantCount = 0;
          updateScrollBottomButton();
          recoverSelectedSessionConnection("visibility", { restartStream: true, silent: true });
        }
      });
      window.addEventListener("beforeinstallprompt", (e) => {
        e.preventDefault();
        state.deferredInstallPrompt = e;
        els.installButton.hidden = false;
      });
      window.addEventListener("appinstalled", () => {
        state.deferredInstallPrompt = null;
        els.installButton.hidden = true;
        toast("App instalada", "success");
      });
    }

    async function handleInstallClick() {
      if (!state.deferredInstallPrompt) {
        toast("Añade al escritorio desde el menú del navegador", "info");
        return;
      }
      state.deferredInstallPrompt.prompt();
      const { outcome } = await state.deferredInstallPrompt.userChoice;
      if (outcome === "accepted") toast("Instalando…", "success");
      state.deferredInstallPrompt = null;
      els.installButton.hidden = true;
    }

    function bindVisualViewport() {
      if (!window.visualViewport) return;
      const vv = window.visualViewport;
      const update = () => {
        const offset = Math.max(0, window.innerHeight - vv.height - vv.offsetTop);
        els.composerDock.style.transform = offset > 0 ? `translateY(${-offset}px)` : "";
      };
      vv.addEventListener("resize", update);
      vv.addEventListener("scroll", update);
    }

    function registerServiceWorker() {
      if (!("serviceWorker" in navigator)) return;
      let refreshing = false;
      navigator.serviceWorker.addEventListener("controllerchange", () => {
        if (refreshing) return;
        refreshing = true;
        window.location.reload();
      });
      navigator.serviceWorker.register("/sw.js")
        .then((registration) => {
          registration.update?.();
        })
        .catch(() => {});
    }

    function openDrawer(open) {
      state.drawerOpen = open;
      els.drawer.dataset.open = open ? "true" : "false";
      els.drawer.setAttribute("aria-hidden", open ? "false" : "true");
    }

    async function refreshAll({ initial = false } = {}) {
      try {
        const ws = await api("/api/workspaces");
        state.workspaces = Array.isArray(ws) ? ws : [];
        if (!state.selectedWorkspaceId && state.workspaces.length) {
          state.selectedWorkspaceId = (state.workspaces.find((w) => w.isDefault) || state.workspaces[0])?.id;
        }
        if (state.selectedWorkspaceId && !state.workspaces.some((w) => w.id === state.selectedWorkspaceId)) {
          state.selectedWorkspaceId = (state.workspaces.find((w) => w.isDefault) || state.workspaces[0])?.id || null;
        }
        const ss = await api(sessionsEndpoint());
        state.sessions = Array.isArray(ss) ? ss : [];
        if (state.selectedSessionId && !findSession(state.selectedSessionId)) {
          state.selectedSessionId = state.sessions[0]?.id || null;
        } else if (!state.selectedSessionId && state.sessions.length) {
          state.selectedSessionId = state.sessions[0].id;
        }
        renderWorkspaceChips();
        renderSessions();
        await renderStageForCurrent();
        renderConnection("ok");
      } catch (err) {
        console.error("[miwhisper] refresh failed", err);
        renderConnection("error", "No puedo contactar con MiWhisper");
        if (initial) throw err;
      }
    }

    function renderConnection(stateName, message) {
      state.connection.state = stateName;
      state.connection.lastError = stateName === "error" ? (message || "Error de conexión") : null;
      if (stateName === "ok") state.lastBridgeContactAt = Date.now();
      els.footerDot.dataset.state = stateName === "error" ? "offline" : (stateName === "warn" ? "degraded" : "");
      if (els.bridgeStatus) {
        if (stateName === "error") {
          const seconds = Math.max(1, Math.round((Date.now() - state.lastBridgeContactAt) / 1000));
          els.bridgeStatus.textContent = `sin conexión · ${seconds}s`;
        } else if (stateName === "warn") {
          els.bridgeStatus.textContent = "reconectando";
        } else {
          els.bridgeStatus.textContent = "conectado";
        }
      }
      if (stateName === "ok" && !message) {
        els.connectionBanner.hidden = true;
        return;
      }
      els.connectionBanner.hidden = false;
      els.connectionBanner.dataset.state = stateName;
      els.connectionBannerText.textContent = message || (stateName === "ok" ? "Conectado" : "Sin conexión");
      els.connectionBannerRetry.hidden = stateName === "ok";
      if (stateName === "ok") {
        setTimeout(() => { els.connectionBanner.hidden = true; }, 1600);
      }
    }

    function showDrawerSkeleton() {
      state.sessionsRenderSignature = "";
      els.sessionList.innerHTML = `
        <div class="skeleton-wrap">
          <div class="skeleton skeleton-line" style="width: 70%"></div>
          <div class="skeleton skeleton-line" style="width: 88%"></div>
          <div class="skeleton skeleton-line" style="width: 52%"></div>
          <div class="skeleton skeleton-line" style="width: 76%"></div>
          <div class="skeleton skeleton-line" style="width: 60%"></div>
        </div>`;
    }

    function showStageSkeleton() {
      state.stageRenderSignature = "";
      els.chatStream.innerHTML = `
        <div class="stage-inner">
          <div class="skeleton-wrap">
            <div class="skeleton skeleton-line" style="width: 40%"></div>
            <div class="skeleton skeleton-block"></div>
            <div class="skeleton skeleton-block" style="height: 110px;"></div>
            <div class="skeleton skeleton-line" style="width: 70%"></div>
            <div class="skeleton skeleton-block" style="height: 80px;"></div>
          </div>
        </div>`;
    }

    function renderWorkspaceChips() {
      els.workspaceChips.innerHTML = "";
      for (const w of state.workspaces) {
        const btn = document.createElement("button");
        btn.type = "button";
        btn.className = "chip";
        btn.dataset.id = w.id;
        if (w.id === state.selectedWorkspaceId) btn.dataset.active = "true";
        btn.innerHTML = `<span class="chip-dot" aria-hidden="true"></span><span>${escapeHTML(w.name)}</span>`;
        btn.title = w.path;
        btn.addEventListener("click", () => {
          if (state.selectedWorkspaceId === w.id) return;
          state.selectedWorkspaceId = w.id;
          state.selectedSessionId = null;
          state.sessionDetail = null;
          localStorage.setItem(STORAGE.workspace, w.id);
          localStorage.removeItem(STORAGE.session);
          renderWorkspaceChips();
          showDrawerSkeleton();
          startSessionsStream();
          renderStageForCurrent();
          refreshAll().catch((err) => {
            console.error("[miwhisper] workspace switch failed", err);
            renderConnection("error", "No se pudo cargar el workspace");
          });
        });
        els.workspaceChips.appendChild(btn);
      }
    }

    function renderSessions() {
      const sessions = filterSessionsForSelectedWorkspace(state.sessions).sort((a, b) => {
        const pa = state.pinned.has(a.id) ? 1 : 0;
        const pb = state.pinned.has(b.id) ? 1 : 0;
        if (pa !== pb) return pb - pa;
        return new Date(b.updatedAt) - new Date(a.updatedAt);
      });
      const signature = sessionsRenderSignature(sessions);
      if (signature === state.sessionsRenderSignature) return;
      state.sessionsRenderSignature = signature;

      els.sessionList.innerHTML = "";
      if (!sessions.length) {
        const workspace = selectedWorkspace();
        const suffix = workspace ? ` en ${escapeHTML(workspace.name)}` : "";
        els.sessionList.innerHTML = `<div class="session-date-label" style="padding: 12px 6px; color: var(--text-faint)">Sin conversaciones${suffix}.</div>`;
        return;
      }

      let lastGroup = null;
      for (const s of sessions) {
        const group = state.pinned.has(s.id) ? "Fijadas" : dayGroup(new Date(s.updatedAt));
        if (group !== lastGroup) {
          const label = document.createElement("div");
          label.className = "session-date-label";
          label.textContent = group;
          els.sessionList.appendChild(label);
          lastGroup = group;
        }
        const item = document.createElement("button");
        item.type = "button";
        item.className = "session-item";
        item.setAttribute("role", "listitem");
        if (sessionMatchesID(s, state.selectedSessionId)) item.dataset.active = "true";
        if (state.archived.has(s.id)) item.dataset.archived = "true";
        const ws = state.workspaces.find((w) => w.id === s.workspaceID);
        const wsName = ws?.name || s.workspaceName || "";
        item.innerHTML = `
          <div class="session-item-main">
            <div class="session-item-title">
              <span class="session-item-title-text">${escapeHTML(s.title || "Sin título")}</span>
              ${state.pinned.has(s.id) ? `<span class="session-item-pin" title="Fijada"><svg viewBox="0 0 24 24" width="12" height="12" aria-hidden="true"><path fill="currentColor" d="M16 3h-1l1 4-4 4h-5l1 8 4-4v6h2v-6l4 4 1-8-4-4 1-4z"/></svg></span>` : ""}
              ${renderSessionStateIndicator(s)}
            </div>
            <div class="session-item-subtitle">
              <span>${escapeHTML(wsName)} · ${timeShort(new Date(s.updatedAt))}</span>
              ${renderSessionStateChip(s)}
            </div>
          </div>
          <div class="session-item-meta">
            <button class="session-item-kebab" type="button" aria-label="Acciones" title="Más acciones">
              <svg viewBox="0 0 24 24" width="16" height="16" aria-hidden="true"><path fill="currentColor" d="M12 8a2 2 0 1 0 0-4 2 2 0 0 0 0 4m0 6a2 2 0 1 0 0-4 2 2 0 0 0 0 4m0 6a2 2 0 1 0 0-4 2 2 0 0 0 0 4"/></svg>
            </button>
          </div>
        `;
        item.addEventListener("click", (e) => {
          if (e.target.closest(".session-item-kebab")) return;
          selectSession(s.id).catch((err) => {
            console.error("[miwhisper] session click failed", err);
            renderConnection("error", "No se pudo abrir la conversación");
          });
        });
        item.querySelector(".session-item-kebab").addEventListener("click", (e) => {
          e.stopPropagation();
          openSessionMenu(s.id, e.currentTarget);
        });
        els.sessionList.appendChild(item);
      }
    }

    function sessionsRenderSignature(sessions) {
      return [state.selectedWorkspaceId || "all", (sessions || []).map((s) => [
        s.id || "",
        s.recordID || "",
        s.threadID || "",
        s.title || "",
        s.workspaceID || "",
        s.workspaceName || "",
        state.pinned.has(s.id) ? "p" : "",
        state.archived.has(s.id) ? "a" : "",
        sessionMatchesID(s, state.selectedSessionId) ? "active" : "",
        s.isBusy ? "busy" : "idle",
        s.liveState || "",
        s.liveLabel || "",
        timeShort(new Date(s.updatedAt || 0)),
      ].join("~")).join("|")].join("::");
    }

    function renderSessionStateIndicator(session) {
      const visual = sessionVisualState(session);
      if (visual.state === "idle" || visual.state === "ready") return "";
      return `<span class="session-state-light" data-state="${escapeHTML(visual.state)}" title="${escapeHTML(visual.label)}"><span>${escapeHTML(visual.icon)}</span></span>`;
    }

    function renderSessionStateChip(session) {
      const visual = sessionVisualState(session);
      if (!session.isBusy && !["attention", "error"].includes(visual.state)) return "";
      return `<span class="session-state-chip" data-state="${escapeHTML(visual.state)}">${escapeHTML(visual.label)}</span>`;
    }

    function sessionVisualState(session) {
      return visualStateFor(session?.liveState || (session?.isBusy ? "running" : "idle"), session?.liveLabel);
    }

    function dayGroup(date) {
      const today = new Date();
      const yday = new Date(); yday.setDate(today.getDate() - 1);
      const sameDay = (a, b) => a.toDateString() === b.toDateString();
      if (sameDay(date, today)) return "Hoy";
      if (sameDay(date, yday)) return "Ayer";
      const days = Math.floor((today - date) / 86400000);
      if (days < 7) return "Últimos 7 días";
      if (days < 30) return "Últimos 30 días";
      return date.toLocaleDateString(undefined, { month: "long", year: "numeric" });
    }

    function timeShort(date) {
      const today = new Date();
      if (date.toDateString() === today.toDateString()) {
        return date.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
      }
      return date.toLocaleDateString([], { month: "short", day: "numeric" });
    }

    async function selectSession(id) {
      state.selectedSessionId = id;
      localStorage.setItem(STORAGE.session, id || "");
      hideSuggestions();
      renderSessions();
      try {
        await renderStageForCurrent();
      } catch (err) {
        console.error("[miwhisper] select session failed", err);
        renderConnection("error", "No se pudo abrir la conversación");
      }
      loadComposerDraft();
      renderFollowupQueue();
      renderRuntimeControls();
      if (state.drawerOpen && matchMedia("(max-width: 900px)").matches) {
        openDrawer(false);
      }
    }

    async function renderStageForCurrent() {
      stopSessionStream();
      state.stageError = null;
      if (!state.selectedSessionId) {
        state.sessionDetail = null;
        renderStage();
        updateTopbar();
        return;
      }
      try {
        const localSessionId = await ensureLocalSessionID(state.selectedSessionId);
        if (localSessionId !== state.selectedSessionId) {
          state.selectedSessionId = localSessionId;
          localStorage.setItem(STORAGE.session, localSessionId);
          renderSessions();
        }
        state.sessionDetail = await api(`/api/sessions/${localSessionId}`);
        state.stageError = null;
        updateTopbar();
        renderStage();
        startSessionStream(localSessionId);
      } catch (err) {
        console.error("[miwhisper] session load failed", err);
        state.sessionDetail = null;
        state.stageError = err?.message || "No se pudo cargar la sesión";
        renderStage();
        updateTopbar();
        // Attempt fallback polling in case SSE fails but REST works after a bit
        schedulePollingFallback();
      }
    }

    async function ensureLocalSessionID(sessionID) {
      const session = findSession(sessionID);
      if (!session) return sessionID;
      if (session.hasLocalSession && session.recordID) return session.recordID;
      if (session.hasLocalSession) return session.id;
      if (!session.threadID) return sessionID;

      const detail = await api("/api/sessions/open-thread", {
        method: "POST",
        json: { threadID: session.threadID, ...runtimeCreateSessionParams() },
      });
      const localID = detail?.session?.id;
      if (!localID) throw new Error("MiWhisper did not return a local session id");

      const index = state.sessions.findIndex((s) => s.id === session.id || s.threadID === session.threadID);
      if (index >= 0) state.sessions[index] = { ...state.sessions[index], ...detail.session };
      else state.sessions.unshift(detail.session);
      state.sessionDetail = detail;
      return localID;
    }

    function findSession(sessionID) {
      return state.sessions.find((s) => (
        sessionMatchesID(s, sessionID)
      ));
    }

    function sessionMatchesID(session, sessionID) {
      if (!session || !sessionID) return false;
      return session.id === sessionID || session.recordID === sessionID || session.threadID === sessionID;
    }

    function sessionsEndpoint() {
      return state.selectedWorkspaceId
        ? `/api/sessions?workspaceID=${encodeURIComponent(state.selectedWorkspaceId)}`
        : "/api/sessions";
    }

    function selectedWorkspace() {
      return state.workspaces.find((w) => w.id === state.selectedWorkspaceId) || null;
    }

    function filterSessionsForSelectedWorkspace(sessions) {
      if (!state.selectedWorkspaceId) return [...sessions];
      return sessions.filter((session) => session.workspaceID === state.selectedWorkspaceId);
    }

    function updateTopbar() {
      const detail = state.sessionDetail;
      const session = detail?.session;
      if (!session) {
        const signature = "empty";
        if (state.topbarSignature !== signature) {
          state.topbarSignature = signature;
          els.sessionTitle.textContent = "Nuevo chat";
          els.sessionTitle.title = "";
          els.sessionSubtitle.textContent = "";
          els.focusButton.hidden = true;
          els.stopButton.hidden = true;
          els.sessionMenuButton.hidden = true;
          document.title = state.titleOriginal;
          els.chatStream.setAttribute("aria-busy", "false");
      }
      renderLiveStrip();
      renderRuntimeControls();
      renderCarModePanel();
      return;
      }
      const ws = state.workspaces.find((w) => w.id === session.workspaceID)?.name || session.workspaceName || "";
      const subtitle = `${ws} · ${session.workingDirectory}`;
      const signature = [
        session.id || "",
        session.title || "",
        subtitle,
        session.hasLocalSession ? "local" : "remote",
        session.isBusy ? "busy" : "idle",
      ].join("|");
      if (state.topbarSignature !== signature) {
        state.topbarSignature = signature;
        els.sessionTitle.textContent = session.title || "Sin título";
        els.sessionTitle.title = session.title || "";
        els.sessionSubtitle.textContent = subtitle;
        els.focusButton.hidden = !session.hasLocalSession;
        els.stopButton.hidden = !session.isBusy;
        els.sessionMenuButton.hidden = false;
        els.chatStream.setAttribute("aria-busy", session.isBusy ? "true" : "false");
        updateDocumentTitle(session);
      }
      renderLiveStrip();
      renderRuntimeControls();
      renderCarModePanel();
    }

    function renderLiveStrip() {
      if (!els.liveStrip) return;
      renderCarModePanel();
      const detail = state.sessionDetail;
      const session = detail?.session;
      if (!session) {
        els.liveStrip.hidden = true;
        if (state.liveStripSignature !== "") {
          state.liveStripSignature = "";
        }
        return;
      }
      const live = liveSnapshotFromDetail(detail);
      const isLive = session.isBusy || ["running", "thinking", "streaming", "command", "tool", "patch"].includes(live.state);
      const thread = session.threadID ? `thread ${shortHash(session.threadID)}` : "thread pending";
      const metrics = liveMetrics(live);
      const signature = [
        session.id || "",
        session.isBusy ? "busy" : "idle",
        live.state || "idle",
        live.label || "",
        live.detail || "",
        thread,
        metrics.join(","),
      ].join("|");
      els.liveStrip.hidden = false;
      els.liveStrip.dataset.state = live.state || "idle";
      els.liveStrip.dataset.live = isLive ? "true" : "false";
      if (signature === state.liveStripSignature) return;
      state.liveStripSignature = signature;
      ensureLiveStripShell();
      const visual = visualStateFor(live.state, live.label || "Codex");
      const glyph = els.liveStrip.querySelector(".state-glyph");
      glyph.dataset.state = visual.state;
      glyph.textContent = visual.icon;
      glyph.title = visual.label;
      els.liveStrip.querySelector(".live-title").textContent = visual.label;
      els.liveStrip.querySelector(".live-source").textContent = thread;
      els.liveStrip.querySelector(".live-detail").textContent = live.detail || session.workingDirectory || "";
      const metricsWrap = els.liveStrip.querySelector(".live-metrics-list");
      const metricsSignature = metrics.join("|");
      if (metricsWrap.dataset.metricsSignature !== metricsSignature) {
        metricsWrap.dataset.metricsSignature = metricsSignature;
        metricsWrap.replaceChildren(...metrics.map((metric) => {
          const span = document.createElement("span");
          span.className = "live-metric";
          span.textContent = metric;
          return span;
        }));
      }
      const stopButton = els.liveStrip.querySelector('[data-live-action="stop"]');
      stopButton.hidden = !session.isBusy;
    }

    function ensureLiveStripShell() {
      if (els.liveStrip.querySelector(".live-strip-main")) return;
      els.liveStrip.innerHTML = `
        <div class="live-strip-main">
          <span class="state-glyph" data-state="idle" aria-hidden="true"></span>
          <span class="live-dot" aria-hidden="true"></span>
          <div class="live-copy">
            <div class="live-title-row">
              <span class="live-title"></span>
              <span class="live-source"></span>
            </div>
            <div class="live-detail"></div>
          </div>
        </div>
        <div class="live-metrics">
          <span class="live-metrics-list"></span>
          <button class="live-action" type="button" data-live-action="focus">Mac</button>
          <button class="live-action" type="button" data-live-action="stop">Stop</button>
        </div>
      `;
      els.liveStrip.querySelector('[data-live-action="focus"]')?.addEventListener("click", () => focusSession(state.selectedSessionId));
      els.liveStrip.querySelector('[data-live-action="stop"]')?.addEventListener("click", () => stopSession(state.selectedSessionId));
    }

    function visualStateFor(rawState, fallbackLabel) {
      const state = rawState || "idle";
      if (state === "thinking") return { state, label: fallbackLabel || "Pensando", icon: "✦" };
      if (["command", "tool", "patch", "running"].includes(state)) return { state, label: fallbackLabel || "Trabajando", icon: "›" };
      if (state === "streaming") return { state, label: fallbackLabel || "Escribiendo", icon: "…" };
      if (state === "attention") return { state, label: fallbackLabel || "Necesita atención", icon: "!" };
      if (state === "error") return { state, label: fallbackLabel || "Error", icon: "!" };
      if (state === "ready") return { state, label: fallbackLabel || "Terminado", icon: "✓" };
      return { state: "idle", label: fallbackLabel || "Thread listo", icon: "•" };
    }

    function renderCarModePanel() {
      if (!els.carModePanel || !state.runtimePrefs.carMode) return;
      const snapshot = carModeSnapshot(state.sessionDetail);
      const signature = [
        snapshot.state,
        snapshot.label,
        snapshot.detail,
        snapshot.title,
        snapshot.summary,
        snapshot.finalKey || "",
        state.runtimePrefs.carVerbosity || "",
        state.runtimePrefs.carArmed ? "armed" : "unarmed",
        state.carCommand.state || "",
        state.carCommand.message || "",
        state.carCommand.transcript || "",
        state.carCommand.promptPending ? "prompt-pending" : "",
        state.recording ? "recording" : "",
        state.voiceProcessing ? "voice-processing" : "",
        state.speech.activeKey || "",
        state.speech.paused ? "paused" : "",
        state.speech.pending ? "speech-pending" : "",
      ].join("|");
      if (signature === state.carModeSignature) return;
      state.carModeSignature = signature;
      els.carModeShell.dataset.state = snapshot.state;
      els.carStatusGlyph.dataset.state = snapshot.state;
      els.carStatusGlyph.textContent = snapshot.icon;
      els.carStatusLabel.textContent = snapshot.label;
      els.carStatusDetail.textContent = snapshot.detail;
      els.carModeTitle.textContent = snapshot.title;
      els.carModeSummary.textContent = snapshot.summary;
      els.carVoiceButton.dataset.recording = state.recording ? "true" : "false";
      els.carVoiceLabel.textContent = state.recording ? "Enviar" : state.voiceProcessing ? "Procesando" : "Hablar";
      els.carVoiceButton.disabled = state.voiceProcessing && !state.recording;
      els.carArmButton.dataset.active = state.runtimePrefs.carArmed ? "true" : "false";
      els.carArmLabel.textContent = state.runtimePrefs.carArmed ? "Armado" : "Armar";
      const hasSpeech = !!state.speech.activeKey;
      els.carStopAudioButton.querySelector("span").textContent = state.recording ? "Cancelar" : hasSpeech ? "Parar" : (state.sessionDetail?.session?.isBusy ? "Detener" : "Parar");
      els.carRepeatButton.disabled = !snapshot.speakText;
      els.carVerbosityButtons.forEach((button) => {
        button.dataset.active = button.dataset.carVerbosity === state.runtimePrefs.carVerbosity ? "true" : "false";
      });
    }

    function carModeSnapshot(detail) {
      const live = liveSnapshotFromDetail(detail || {});
      const session = detail?.session || null;
      let rawState = live?.state || (session?.isBusy ? "running" : "idle");
      let label = "Terminado";
      let icon = "✓";
      let detailText = session?.title || "Toca el micro para dictar un prompt.";
      if (state.recording) {
        rawState = "listening";
        label = "Escuchando";
        icon = "●";
        detailText = "Toca otra vez para enviar el dictado.";
      } else if (state.voiceProcessing) {
        rawState = "thinking";
        label = "Pensando";
        icon = "…";
        detailText = "Transcribiendo tu voz.";
      } else if (state.runtimePrefs.carArmed && !session?.isBusy && !state.speech.activeKey) {
        if (state.carCommand.promptPending || state.carCommand.state === "submitted") {
          rawState = "thinking";
          label = "Enviando";
          icon = "…";
          detailText = state.carCommand.transcript ? compactInline(state.carCommand.transcript, 120) : "Enviando prompt.";
        } else if (state.carCommand.state === "dictating") {
          rawState = "listening";
          label = "Dictando";
          icon = "●";
          detailText = state.carCommand.transcript ? compactInline(state.carCommand.transcript, 120) : "Habla. Enviaré al detectar 2 segundos de silencio.";
        } else if (state.carCommand.state === "error") {
          rawState = "attention";
          label = "Necesita atención";
          icon = "!";
          detailText = compactInline(state.carCommand.message || "No puedo armar la escucha nativa.", 120);
        } else {
          rawState = "listening";
          label = "Armado";
          icon = "●";
          detailText = state.carCommand.message || "Di “oye Codex” y dicta el prompt.";
        }
      } else if (rawState === "attention" || live?.needsAttention) {
        label = "Necesita atención";
        icon = "!";
        detailText = compactInline(live?.detail || live?.label || "Codex necesita una decisión.", 120);
      } else if (rawState === "error") {
        label = "Necesita atención";
        icon = "!";
        detailText = compactInline(live?.detail || "Codex encontró un error.", 120);
      } else if (["thinking", "streaming"].includes(rawState)) {
        label = "Pensando";
        icon = "✦";
        detailText = compactInline(live?.detail || live?.label || "Codex está preparando la respuesta.", 120);
      } else if (["command", "tool", "patch", "running"].includes(rawState) || session?.isBusy) {
        rawState = ["command", "tool", "patch"].includes(rawState) ? rawState : "working";
        label = "Trabajando";
        icon = "›";
        detailText = compactInline(live?.detail || live?.label || "Codex está ejecutando trabajo en el Mac.", 120);
      } else if (session) {
        rawState = "ready";
        label = "Terminado";
        icon = "✓";
        detailText = session.title || "Thread listo.";
      } else {
        rawState = "idle";
        label = "Terminado";
        icon = "•";
      }

      const finalEntry = latestFinalEntryFromDetail(detail);
      const finalText = finalEntry ? normalizeSpeechText(finalEntry.detail || "") : "";
      const summary = finalText
        ? carSummaryFromText(finalText, state.runtimePrefs.carVerbosity)
        : "Dicta un prompt. Si Codex termina mientras este modo está activo, leeré solo un resumen.";
      const title = session?.title || "Modo coche";
      const finalKey = finalEntry ? timelineKeyForEntry(finalEntry, { turnID: "car", index: 0 }) : null;
      const speakText = finalText ? carSpokenSummary(summary, { label, needsAttention: rawState === "attention" || rawState === "error" }) : "";
      return { state: rawState, label, icon, detail: detailText, title, summary, finalKey, speakText };
    }

    function latestFinalEntryFromDetail(detail) {
      const entries = ensureFinalActivity(detail?.activity || [], detail?.session?.latestResponse || "");
      for (let i = entries.length - 1; i >= 0; i--) {
        const entry = entries[i];
        if (entry.blockKind === "final" && (entry.detail || "").trim()) return entry;
      }
      return null;
    }

    function carSummaryFromText(text, verbosity = "brief") {
      const clean = normalizeSpeechText(text);
      if (!clean) return "";
      const explicit = extractExplicitCarSummary(clean);
      const source = explicit || clean;
      if (verbosity === "detail") return limitSentences(source, 8, 980);
      if (verbosity === "normal") return limitSentences(source, 4, 560);
      return limitSentences(source, 2, 300);
    }

    function extractExplicitCarSummary(text) {
      const match = String(text || "").match(/resumen para coche\s*:?\s*([\s\S]+)/i);
      if (!match) return "";
      const after = match[1].trim();
      if (!after) return "";
      const nextSection = after.search(/\n\s*(?:#{1,6}\s+)?[A-ZÁÉÍÓÚÑ][^:\n]{2,48}:\s*(?:\n|$)/);
      const block = nextSection > 0 ? after.slice(0, nextSection) : after;
      return block.trim();
    }

    function limitSentences(text, maxSentences, maxChars) {
      const normalized = String(text || "")
        .replace(/\s+/g, " ")
        .replace(/\b(?:diff|patch|tool|output|stdout|stderr)\b/gi, "")
        .trim();
      if (!normalized) return "";
      const sentences = normalized.match(/[^.!?]+[.!?]+|[^.!?]+$/g) || [normalized];
      let out = "";
      for (const sentence of sentences) {
        const next = sentence.trim();
        if (!next) continue;
        if (out && (out + " " + next).length > maxChars) break;
        out = out ? `${out} ${next}` : next;
        if (out.split(/(?<=[.!?])\s+/).filter(Boolean).length >= maxSentences) break;
      }
      if (!out) out = normalized.slice(0, maxChars).trim();
      if (out.length > maxChars) out = out.slice(0, maxChars - 1).trimEnd() + "…";
      return out;
    }

    function carSpokenSummary(summary, options = {}) {
      const body = normalizeSpeechText(summary);
      if (!body) return "";
      if (options.needsAttention) return `Necesito atención. ${body}`;
      return `He terminado. ${body}`;
    }

    function carNarrationTiming(verbosity = state.runtimePrefs.carVerbosity) {
      if (verbosity === "detail") return { firstDelay: 22_000, cooldown: 38_000 };
      if (verbosity === "normal") return { firstDelay: 32_000, cooldown: 55_000 };
      return { firstDelay: 48_000, cooldown: 85_000 };
    }

    function carProgressNarration(detail, snapshot) {
      const live = detail?.live || {};
      const latest = latestNarratableProgressEntry(detail);
      const liveState = String(live.state || snapshot?.state || "").toLowerCase();
      const sourceText = narratableProgressText(latest?.detail || live.activeDetail || live.detail || "");

      if (liveState === "attention" || live.needsAttention) {
        return `Necesito atención. ${compactInline(live.detail || live.label || "Codex necesita una decisión.", 180)}`;
      }
      if (liveState === "error") {
        return "Ha aparecido un fallo intermedio. Codex sigue trabajando; te avisaré si acaba bloqueado.";
      }

      const kind = latest?.blockKind || live.latestKind || liveState;
      if (kind === "reasoning" || liveState === "thinking") {
        return sourceText ? `Estoy pensando. ${sourceText}` : "Estoy pensando y organizando la siguiente acción.";
      }
      if (kind === "patch" || liveState === "patch") {
        return sourceText ? `Estoy editando archivos. ${sourceText}` : "Estoy editando archivos en tu Mac.";
      }
      if (kind === "command" || liveState === "command") {
        return "Estoy ejecutando comandos en tu Mac.";
      }
      if (kind === "tool" || liveState === "tool") {
        return sourceText ? `Estoy revisando resultados. ${sourceText}` : "Estoy usando herramientas y revisando resultados.";
      }
      if (liveState === "streaming") {
        return "Estoy redactando la respuesta.";
      }
      return "Sigo trabajando en tu Mac.";
    }

    function latestNarratableProgressEntry(detail) {
      const entries = detail?.activity || [];
      for (let i = entries.length - 1; i >= 0; i--) {
        const entry = entries[i] || {};
        if (!["reasoning", "patch", "command", "tool"].includes(entry.blockKind)) continue;
        if (entry.kind === "error" || entry.kind === "warning") continue;
        return entry;
      }
      return null;
    }

    function narratableProgressText(text) {
      const clean = normalizeSpeechText(text);
      if (!clean) return "";
      if (looksLikeDiff(clean)) return "";
      if (/^\s*(?:error|warning|stdout|stderr|traceback|exception|failed|diff --git)\b/i.test(clean)) return "";
      if (/[{}()[\];=<>]/.test(clean.slice(0, 220)) && clean.split(/\s+/).length < 18) return "";
      return limitSentences(clean, 1, 190);
    }

    function carProgressKey(detail, snapshot) {
      const live = detail?.live || {};
      const latest = latestNarratableProgressEntry(detail);
      return [
        detail?.session?.id || "",
        live.state || snapshot?.state || "",
        live.label || "",
        latest?.id || latest?.sourceID || latest?.groupID || latest?.title || "",
        compactInline(latest?.detail || live.activeDetail || live.detail || "", 60)
      ].join("|");
    }

    function nativeCarModeBridge() {
      return window.miwhisperNativeCarMode && window.miwhisperNativeCarMode.isAvailable
        ? window.miwhisperNativeCarMode
        : null;
    }

    function nativeCarCommandShouldListen(detail = state.sessionDetail) {
      const sessionBusy = detail?.session?.isBusy === true;
      return !!(
        nativeCarModeBridge() &&
        state.runtimePrefs.carMode &&
        state.runtimePrefs.carArmed &&
        !state.carCommand.promptPending &&
        !state.recording &&
        !state.voiceProcessing &&
        !state.speech.activeKey
      );
    }

    function syncNativeCarCommandListening(detail = state.sessionDetail, options = {}) {
      const bridge = nativeCarModeBridge();
      const shouldListen = nativeCarCommandShouldListen(detail);
      if (!bridge) {
        state.carCommand.listeningRequested = false;
        return;
      }

      if (!shouldListen) {
        if (state.carCommand.listeningRequested) {
          try { bridge.disarm({ reason: options.reason || "inactive" }); } catch {}
        }
        state.carCommand.listeningRequested = false;
        if (!state.runtimePrefs.carArmed) {
          state.carCommand.state = "off";
          state.carCommand.message = "";
          state.carCommand.transcript = "";
        } else if (state.speech.activeKey) {
          state.carCommand.state = "paused";
          state.carCommand.message = "Pausado mientras leo la respuesta.";
        }
        renderCarModePanel();
        return;
      }

      if (state.carCommand.listeningRequested) return;
      try {
        bridge.arm({ silenceSeconds: 2 });
        state.carCommand.listeningRequested = true;
        state.carCommand.state = "listening";
        state.carCommand.message = "Di oye Codex para dictar.";
        state.carCommand.transcript = "";
        renderCarModePanel();
      } catch (err) {
        state.carCommand.listeningRequested = false;
        state.carCommand.state = "error";
        state.carCommand.message = "No puedo armar la escucha nativa.";
        console.debug("[miwhisper] native car command arm failed", err);
        renderCarModePanel();
      }
    }

    async function handleNativeCarCommandEvent(event) {
      const detail = event?.detail || {};
      state.carCommand.state = detail.state || detail.type || "listening";
      state.carCommand.message = detail.message || "";
      state.carCommand.transcript = detail.transcript || "";
      renderCarModePanel();

      if (detail.type === "error") {
        toast(detail.message || "No puedo armar la escucha de coche", "error", 3200);
        state.carCommand.listeningRequested = false;
        return;
      }

      if (detail.type !== "prompt") return;
      const prompt = String(detail.prompt || detail.transcript || "").trim();
      if (!prompt) return;

      if (state.sessionDetail?.session?.isBusy && isCarStopCommand(prompt)) {
        state.carCommand.promptPending = false;
        state.carCommand.listeningRequested = false;
        state.carCommand.state = "submitted";
        state.carCommand.message = "Deteniendo Codex.";
        state.carCommand.transcript = prompt;
        renderCarModePanel();
        startSpeech(`car-stop-${Date.now()}`, "Deteniendo Codex.");
        await stopSession(state.selectedSessionId);
        syncNativeCarCommandListening(state.sessionDetail, { reason: "voice-stop" });
        return;
      }

      state.carCommand.promptPending = true;
      state.carCommand.listeningRequested = false;
      state.carCommand.state = "submitted";
      state.carCommand.message = "Enviando prompt.";
      state.carCommand.transcript = prompt;
      renderCarModePanel();

      els.composer.value = prompt;
      autoGrow();
      saveDraft(state.selectedSessionId, prompt);
      try {
        await sendComposer();
      } finally {
        state.carCommand.promptPending = false;
        syncNativeCarCommandListening(state.sessionDetail, { reason: "prompt-finished" });
      }
    }

    function isCarStopCommand(text) {
      const normalized = normalizeSpeechText(text)
        .toLowerCase()
        .normalize("NFD")
        .replace(/[\u0300-\u036f]/g, "")
        .replace(/[^\p{L}\p{N}\s]/gu, " ")
        .replace(/\s+/g, " ")
        .trim();
      if (!normalized) return false;
      return [
        "para",
        "parar",
        "deten",
        "detener",
        "detente",
        "cancela",
        "cancelar",
        "stop",
        "para codex",
        "deten codex",
        "detener codex",
        "cancela codex",
        "para el proceso",
        "deten el proceso",
        "detener el proceso",
        "cancela el proceso",
        "para la ejecucion",
        "deten la ejecucion",
      ].includes(normalized);
    }

    function stopNativeCarWatch(reason = "stop") {
      const bridge = nativeCarModeBridge();
      const wasWatching = !!state.carMode.nativeWatchSessionId;
      state.carMode.nativeWatchSessionId = null;
      state.carMode.nativeWatchVerbosity = null;
      if (!bridge || !wasWatching) return;
      try {
        bridge.stop({ reason });
      } catch (err) {
        console.debug("[miwhisper] native car watch stop failed", err);
      }
    }

    function restartNativeCarWatch(reason = "restart") {
      if (!state.carMode.nativeWatchSessionId) return;
      stopNativeCarWatch(reason);
    }

    function syncNativeCarWatch(detail, options = {}) {
      const bridge = nativeCarModeBridge();
      const session = detail?.session;
      if (!bridge || !session?.id) return;

      if (!state.runtimePrefs.carMode) {
        stopNativeCarWatch(options.reason || "car-mode-off");
        return;
      }

      if (!session.isBusy) {
        if (!document.hidden) stopNativeCarWatch(options.reason || "complete-visible");
        return;
      }

      const verbosity = state.runtimePrefs.carVerbosity || "brief";
      if (
        state.carMode.nativeWatchSessionId === session.id &&
        state.carMode.nativeWatchVerbosity === verbosity
      ) {
        return;
      }

      try {
        bridge.watch({
          baseURL: location.origin,
          sessionID: session.id,
          verbosity,
          reason: options.reason || "busy",
        });
        state.carMode.nativeWatchSessionId = session.id;
        state.carMode.nativeWatchVerbosity = verbosity;
      } catch (err) {
        state.carMode.nativeWatchSessionId = null;
        state.carMode.nativeWatchVerbosity = null;
        console.debug("[miwhisper] native car watch failed", err);
      }
    }

    function speakCarSummary({ force = false } = {}) {
      if (!state.runtimePrefs.carMode && !force) return;
      const snapshot = carModeSnapshot(state.sessionDetail);
      if (!snapshot.speakText) {
        toast("Todavía no hay respuesta para leer", "info", 1400);
        return;
      }
      const key = `car-${snapshot.finalKey || "latest"}-${state.runtimePrefs.carVerbosity}`;
      startSpeech(key, snapshot.speakText);
    }

    function maybeSpeakCarUpdate(prev, detail) {
      if (!state.runtimePrefs.carMode || !detail?.session) return;
      if (document.hidden && state.carMode.nativeWatchSessionId && nativeCarModeBridge()) return;
      const snapshot = carModeSnapshot(detail);

      if (detail.session.isBusy && !prev?.session?.isBusy) {
        state.carMode.busyStartedAt = Date.now();
        state.carMode.lastSpokenProgressKey = null;
        state.carMode.lastProgressSpokenAt = 0;
      } else if (!detail.session.isBusy) {
        state.carMode.busyStartedAt = 0;
        state.carMode.lastSpokenProgressKey = null;
        state.carMode.lastProgressSpokenAt = 0;
      }

      if ((snapshot.state === "attention" || detail.live?.needsAttention) && snapshot.detail !== state.carMode.lastSpokenAttentionKey) {
        state.carMode.lastSpokenAttentionKey = snapshot.detail;
        startSpeech(`car-attention-${Date.now()}`, `Necesito atención. ${snapshot.detail}`);
        return;
      }
      if (detail.session.isBusy) {
        maybeSpeakCarProgress(detail, snapshot);
        return;
      }
      if (!detail.session.isBusy && snapshot.finalKey && snapshot.speakText && snapshot.finalKey !== state.carMode.lastSpokenFinalKey) {
        const prevFinal = latestFinalEntryFromDetail(prev);
        const prevKey = prevFinal ? timelineKeyForEntry(prevFinal, { turnID: "car", index: 0 }) : null;
        if (prevKey === snapshot.finalKey && prev?.session?.isBusy !== true) return;
        state.carMode.lastSpokenFinalKey = snapshot.finalKey;
        startSpeech(`car-${snapshot.finalKey}-${state.runtimePrefs.carVerbosity}`, snapshot.speakText);
      }
    }

    function maybeSpeakCarProgress(detail, snapshot) {
      if (state.speech.activeKey || state.recording || state.voiceProcessing) return;
      const now = Date.now();
      const timing = carNarrationTiming();
      const busyStartedAt = state.carMode.busyStartedAt || now;
      state.carMode.busyStartedAt = busyStartedAt;
      if (now - busyStartedAt < timing.firstDelay) return;
      if (now - state.carMode.lastProgressSpokenAt < timing.cooldown) return;

      const phrase = carProgressNarration(detail, snapshot);
      if (!phrase) return;
      const key = carProgressKey(detail, snapshot);
      if (key === state.carMode.lastSpokenProgressKey && now - state.carMode.lastProgressSpokenAt < timing.cooldown * 2) return;
      state.carMode.lastSpokenProgressKey = key;
      state.carMode.lastProgressSpokenAt = now;
      startSpeech(`car-progress-${now}`, phrase);
    }

    function handleCarStop() {
      if (state.recording) {
        stopRecording({ cancel: true });
        return;
      }
      if (state.speech.activeKey) {
        stopSpeech();
        return;
      }
      if (state.sessionDetail?.session?.isBusy) {
        stopSession(state.selectedSessionId);
        return;
      }
      toast("No hay audio ni run activa", "info", 1000);
    }

    function liveSnapshotFromDetail(detail) {
      if (detail?.live) return detail.live;
      const session = detail?.session || {};
      const entries = detail?.activity || [];
      const latest = entries[entries.length - 1] || null;
      return {
        state: session.isBusy ? "running" : "idle",
        label: session.isBusy ? "Codex trabajando" : "Listo",
        detail: latest?.detail || latest?.title || session.latestResponse || "",
        commandCount: entries.filter((e) => e.blockKind === "command").length,
        toolCount: entries.filter((e) => e.blockKind === "tool").length,
        patchCount: entries.filter((e) => e.blockKind === "patch").length,
        fileCount: uniqueFiles(entries).length,
        warningCount: entries.filter((e) => e.kind === "warning").length,
        errorCount: entries.filter((e) => e.kind === "error").length,
        needsAttention: entries.some((e) => e.kind === "warning" && /needs attention/i.test(e.title || "")),
      };
    }

    function liveMetrics(live) {
      const out = [];
      if (live.commandCount) out.push(`${live.commandCount} cmd`);
      if (live.toolCount) out.push(`${live.toolCount} tool`);
      if (live.patchCount) out.push(`${live.patchCount} patch`);
      if (live.fileCount) out.push(`${live.fileCount} file`);
      if (live.warningCount) out.push(`${live.warningCount} warn`);
      if (live.errorCount) out.push(`${live.errorCount} err`);
      return out.length ? out.slice(0, 5) : ["live"];
    }

    function shortHash(value) {
      const raw = String(value || "");
      if (raw.length <= 8) return raw;
      return raw.slice(0, 8);
    }

    function updateDocumentTitle(session) {
      if (!session) {
        document.title = state.titleOriginal;
        return;
      }
      const base = session.title || "MiWhisper";
      if (document.hidden && session.isBusy) {
        document.title = `● ${base} — pensando…`;
      } else if (document.hidden && state.unseenAssistantCount > 0) {
        document.title = `(${state.unseenAssistantCount}) ${base}`;
      } else {
        document.title = `${base} · MiWhisper`;
      }
    }

    function renderStage() {
      const detail = state.sessionDetail;
      if (state.stageError) {
        const signature = `error:${state.stageError}`;
        if (signature === state.stageRenderSignature) return;
        state.stageRenderSignature = signature;
        renderStageError(state.stageError);
        return;
      }
      if (!detail) {
        if (state.stageRenderSignature === "empty") return;
        state.stageRenderSignature = "empty";
        renderEmptyStage();
        return;
      }
      const signature = stageRenderSignature(detail);
      if (signature === state.stageRenderSignature) {
        updateScrollBottomButton();
        return;
      }
      state.stageRenderSignature = signature;
      let inner = els.chatStream.querySelector(":scope > .stage-inner");
      if (!inner) {
        els.chatStream.innerHTML = "";
        inner = document.createElement("div");
        inner.className = "stage-inner";
        els.chatStream.appendChild(inner);
      }

      const entries = ensureFinalActivity(detail.activity || [], detail.session?.latestResponse || "");
      const turns = buildTurns(entries);
      const nextNodes = [];
      for (const turn of turns) {
        const node = renderTurn(turn, { isBusy: detail.session?.isBusy && turn === turns[turns.length - 1] });
        collectStageNodes(node, nextNodes);
      }

      // Optimistic bubbles awaiting send
      for (const opt of state.retryQueue.filter((r) => r.sessionID === state.selectedSessionId)) {
        collectStageNodes(renderRetryBubble(opt), nextNodes);
      }

      if (detail.session?.isBusy) {
        collectStageNodes(renderThinking(detail), nextNodes);
      }

      patchStageInner(inner, nextNodes);
      syncSpeechUI();
      if (state.pinnedToBottom) requestAnimationFrame(() => scrollToBottom("auto"));
      updateScrollBottomButton();
    }

    function collectStageNodes(node, out) {
      if (!node) return;
      if (node.nodeType === Node.DOCUMENT_FRAGMENT_NODE) {
        out.push(...Array.from(node.childNodes).filter((child) => child.nodeType === Node.ELEMENT_NODE));
        return;
      }
      if (node.nodeType === Node.ELEMENT_NODE) out.push(node);
    }

    function patchStageInner(inner, nextNodes) {
      const currentByKey = new Map();
      Array.from(inner.children).forEach((node, index) => {
        currentByKey.set(node.dataset.stageKey || `legacy-${index}`, node);
      });

      let anchor = null;
      for (const next of nextNodes) {
        const key = next.dataset.stageKey || `next-${Math.random().toString(36).slice(2)}`;
        next.dataset.stageKey = key;
        const current = currentByKey.get(key);
        let nodeToPlace = next;
        if (current) {
          currentByKey.delete(key);
          if (current.dataset.stageSignature === next.dataset.stageSignature) {
            nodeToPlace = current;
          } else if (patchReusableStageNode(current, next)) {
            nodeToPlace = current;
          } else {
            inner.replaceChild(next, current);
          }
        }
        const expectedBefore = anchor ? anchor.nextSibling : inner.firstChild;
        if (nodeToPlace !== expectedBefore) {
          inner.insertBefore(nodeToPlace, expectedBefore);
        }
        anchor = nodeToPlace;
      }

      for (const stale of currentByKey.values()) {
        stale.remove();
      }
      syncSpeechUI();
    }

    function patchReusableStageNode(current, next) {
      const key = current.dataset.stageKey || "";
      if (!key || key !== next.dataset.stageKey) return false;
      if (current.tagName !== next.tagName) return false;
      if (!/^(assistant-|thinking-)/.test(key)) return false;

      patchAttributes(current, next);
      if (key.startsWith("assistant-")) {
        return patchAssistantStageNode(current, next);
      }

      current.replaceChildren(...Array.from(next.childNodes));
      return true;
    }

    function patchAttributes(current, next) {
      for (const attr of Array.from(current.attributes)) {
        if (!next.hasAttribute(attr.name)) current.removeAttribute(attr.name);
      }
      for (const attr of Array.from(next.attributes)) {
        current.setAttribute(attr.name, attr.value);
      }
    }

    function patchAssistantStageNode(current, next) {
      const currentBlock = current.querySelector(":scope > .assistant-block");
      const nextBlock = next.querySelector(":scope > .assistant-block");
      if (!currentBlock || !nextBlock) {
        current.replaceChildren(...Array.from(next.childNodes));
        return true;
      }

      patchAttributes(currentBlock, nextBlock);
      const currentHeader = currentBlock.querySelector(":scope > .assistant-block-header");
      const nextHeader = nextBlock.querySelector(":scope > .assistant-block-header");
      if (currentHeader && nextHeader && currentHeader.innerHTML !== nextHeader.innerHTML) {
        currentHeader.innerHTML = nextHeader.innerHTML;
      }

      const currentTimeline = currentBlock.querySelector(":scope .assistant-timeline");
      const nextTimeline = nextBlock.querySelector(":scope .assistant-timeline");
      if (currentTimeline && nextTimeline) {
        patchTimelineChildren(currentTimeline, Array.from(nextTimeline.children));
      } else {
        const currentBody = currentBlock.querySelector(":scope > .assistant-body");
        const nextBody = nextBlock.querySelector(":scope > .assistant-body");
        if (currentBody && nextBody) currentBody.replaceChildren(...Array.from(nextBody.childNodes));
      }
      attachPersistentDisclosures(current);
      attachApprovalActions(current);
      return true;
    }

    function patchTimelineChildren(currentTimeline, nextChildren) {
      const currentByKey = new Map();
      Array.from(currentTimeline.children).forEach((node, index) => {
        currentByKey.set(node.dataset.timelineKey || `legacy-${index}`, node);
      });

      let anchor = null;
      for (const next of nextChildren) {
        const key = next.dataset.timelineKey || `timeline-${Math.random().toString(36).slice(2)}`;
        next.dataset.timelineKey = key;
        const current = currentByKey.get(key);
        let nodeToPlace = next;
        if (current) {
          currentByKey.delete(key);
          if (current.dataset.timelineSignature === next.dataset.timelineSignature) {
            nodeToPlace = current;
          } else if (patchTimelineChild(current, next)) {
            nodeToPlace = current;
          } else {
            currentTimeline.replaceChild(next, current);
          }
        }

        const expectedBefore = anchor ? anchor.nextSibling : currentTimeline.firstChild;
        if (nodeToPlace !== expectedBefore) {
          currentTimeline.insertBefore(nodeToPlace, expectedBefore);
        }
        anchor = nodeToPlace;
      }

      for (const stale of currentByKey.values()) {
        stale.remove();
      }
    }

    function patchTimelineChild(current, next) {
      if (current.tagName !== next.tagName) return false;
      patchAttributes(current, next);
      if (current.classList.contains("assistant-timeline-text")) {
        const currentLabel = current.querySelector(":scope > .assistant-timeline-label");
        const nextLabel = next.querySelector(":scope > .assistant-timeline-label");
        if (currentLabel && nextLabel) currentLabel.textContent = nextLabel.textContent;
        else if (!currentLabel && nextLabel) current.insertBefore(nextLabel, current.firstChild);
        else if (currentLabel && !nextLabel) currentLabel.remove();

        const currentActions = current.querySelector(":scope > .assistant-response-actions");
        const nextActions = next.querySelector(":scope > .assistant-response-actions");
        if (currentActions && nextActions && currentActions.innerHTML !== nextActions.innerHTML) {
          currentActions.innerHTML = nextActions.innerHTML;
        } else if (!currentActions && nextActions) {
          current.insertBefore(nextActions, current.querySelector(":scope > .assistant-response"));
        } else if (currentActions && !nextActions) {
          currentActions.remove();
        }

        const currentResponse = current.querySelector(":scope > .assistant-response");
        const nextResponse = next.querySelector(":scope > .assistant-response");
        if (currentResponse && nextResponse) {
          patchAttributes(currentResponse, nextResponse);
          if (currentResponse.innerHTML !== nextResponse.innerHTML) {
            currentResponse.innerHTML = nextResponse.innerHTML;
          }
          return true;
        }
      }
      current.replaceChildren(...Array.from(next.childNodes));
      return true;
    }

    function scheduleStageRender() {
      if (state.pendingStageRender) return;
      state.pendingStageRender = requestAnimationFrame(() => {
        state.pendingStageRender = null;
        renderStage();
      });
    }

    function stageRenderSignature(detail) {
      const session = detail?.session || {};
      const retries = state.retryQueue
        .filter((r) => r.sessionID === state.selectedSessionId)
        .map((r) => [r.id, r.status, r.mode, r.prompt].join("~"))
        .join("|");
      return [
        session.id || "",
        session.isBusy ? "busy" : "idle",
        session.latestResponse || "",
        session.isBusy ? liveSignature(detail?.live) : "",
        activitySignature(detail?.activity || []),
        retries,
      ].join("::");
    }

    function renderEmptyStage() {
      els.chatStream.innerHTML = "";
      const inner = document.createElement("div");
      inner.className = "stage-inner";
      const empty = document.createElement("div");
      empty.className = "empty-state";
      empty.innerHTML = `
        <div class="empty-hero">
          <img class="empty-hero-mark" src="/app-icon.png" alt="" aria-hidden="true">
        </div>
        <h2>¿En qué trabajamos?</h2>
        <p>Escribe a Codex o dicta con MiWhisper. Las sesiones se mantienen conectadas al Mac y al historial real del workspace.</p>
        <div class="suggestion-grid">
          <button class="suggestion-card" data-prompt="Resume los cambios recientes en este workspace y dime en qué debería enfocarme ahora.">
            <strong>Resume</strong>
            <span>Lee el estado del workspace y prioriza.</span>
          </button>
          <button class="suggestion-card" data-prompt="Revisa los TODOs y bugs pendientes y dame un plan para esta semana.">
            <strong>Plan</strong>
            <span>Estructura antes de ejecutar.</span>
          </button>
          <button class="suggestion-card" data-prompt="Explícame la arquitectura principal del proyecto con un diagrama de texto y puntos clave.">
            <strong>Explora</strong>
            <span>Explica arquitectura y puntos clave.</span>
          </button>
          <button class="suggestion-card" data-prompt="Busca código que huela mal, dame un ranking de refactors por ROI y riesgo.">
            <strong>Revisa</strong>
            <span>Detecta bugs, deuda y riesgo.</span>
          </button>
        </div>
      `;
      empty.querySelectorAll(".suggestion-card").forEach((card) => {
        card.addEventListener("click", () => {
          els.composer.value = card.dataset.prompt;
          autoGrow();
          els.composer.focus();
        });
      });
      inner.appendChild(empty);
      els.chatStream.appendChild(inner);
    }

    function renderStageError(message) {
      els.chatStream.innerHTML = "";
      const inner = document.createElement("div");
      inner.className = "stage-inner";
      const box = document.createElement("div");
      box.className = "stage-error";
      box.innerHTML = `<strong>No se pudo cargar la sesión</strong><span>${escapeHTML(message)}</span>`;
      inner.appendChild(box);
      els.chatStream.appendChild(inner);
    }

    function buildTurns(entries) {
      const turns = [];
      let currentTurn = null;
      for (const entry of normalizeActivityEntries(entries)) {
        if (entry.kind === "user") {
          currentTurn = { id: `turn-${entry.id}`, userEntry: entry, assistantEntries: [] };
          turns.push(currentTurn);
          continue;
        }
        if (!currentTurn) {
          currentTurn = { id: `assistant-only-${entry.groupID || entry.id}`, userEntry: null, assistantEntries: [] };
          turns.push(currentTurn);
        }
        currentTurn.assistantEntries.push(entry);
      }
      return turns.filter((turn) => turn.userEntry || turn.assistantEntries.length);
    }

    function ensureFinalActivity(entries, latestResponse) {
      const latest = (latestResponse || "").trim();
      if (!latest) return entries;
      const hasFinal = entries.some((e) => e.blockKind === "final" && ((e.detail || "").trim()));
      if (hasFinal) return entries;
      return entries.concat([{
        id: "synthetic-final",
        kind: "assistant",
        blockKind: "final",
        title: "Codex",
        detail: latest,
        detailStyle: "body",
        groupID: "synthetic-final",
        createdAt: new Date().toISOString()
      }]);
    }

    function normalizeActivityEntries(entries) {
      return (entries || []).filter((entry) => {
        if (!entry) return false;
        if (entry.kind === "user") return true;
        if (isRoutineSystemEntry(entry)) return false;
        if (entry.kind === "error" || entry.kind === "warning") return true;
        if ((entry.blockKind || entry.kind) === "final" && !(entry.detail || "").trim()) return false;
        if ((entry.blockKind || entry.kind) === "system") return systemEntryHasUsefulContent(entry);
        if ((entry.blockKind || entry.kind) === "reasoning") return reasoningEntryHasUsefulContent(entry);
        return entryHasReadableContent(entry) || (entry.relatedFiles || []).length > 0 || !!entry.command;
      });
    }

    function entryHasReadableContent(entry) {
      return Boolean((entry.detail || "").trim() || (entry.title || "").trim() || entry.command || (entry.relatedFiles || []).length);
    }

    function reasoningEntryHasUsefulContent(entry) {
      return Boolean((entry.detail || "").trim() || (entry.relatedFiles || []).length);
    }

    function systemEntryHasUsefulContent(entry) {
      const title = String(entry.title || "");
      if (/^(Codex Turn Started|Turn Steer Requested|Thread Started|Thread Closed|Turn Started|Turn Completed|Thread Active|Item Started|Item Completed|Codex App-Server)$/i.test(title)) {
        return false;
      }
      return Boolean((entry.detail || "").trim() || (entry.relatedFiles || []).length);
    }

    function isRoutineSystemEntry(entry) {
      const title = String(entry.title || "");
      const detail = String(entry.detail || "");
      if (entry.kind === "error" || entry.kind === "warning") return false;
      if ((entry.blockKind || entry.kind) !== "system") return false;
      if (/^(Codex Turn Started|Turn Steer Requested|Thread Started|Thread Closed|Turn Started|Turn Completed|Thread Active|Item Started|Item Completed|Codex App-Server|Codex Log)$/i.test(title)) return true;
      if (/^(thread|turn|item)[-_ ]?[a-z0-9]+$/i.test(detail.trim())) return true;
      return false;
    }

    function renderTurn(turn, options = {}) {
      const frag = document.createDocumentFragment();
      if (turn.userEntry) {
        const userNode = renderUserMessage(turn.userEntry);
        if (userNode) frag.appendChild(userNode);
      }
      if (turn.assistantEntries.length) {
        const assistantNode = renderAssistantTurn(turn, options);
        if (assistantNode) frag.appendChild(assistantNode);
      }
      return frag;
    }

    function renderUserMessage(entry) {
      const wrap = document.createElement("div");
      wrap.className = "segment segment-user";
      wrap.dataset.entryId = entry.id;
      const text = entry.detail || entry.title || "";
      wrap.dataset.stageKey = `user-${entry.id || detailSignature(text)}`;
      wrap.dataset.stageSignature = ["user", entry.createdAt || "", detailSignature(text)].join("~");
      wrap.innerHTML = `
        <div class="user-bubble">${escapeHTML(text)}</div>
        <div class="message-meta">
          <button type="button" class="copy-user" aria-label="Copiar">Copiar</button>
        </div>
      `;
      wrap.querySelector(".copy-user").addEventListener("click", async () => {
        await navigator.clipboard?.writeText(text).catch(() => {});
        toast("Copiado", "success", 1200);
      });
      return wrap;
    }

    function renderRetryBubble(item) {
      const wrap = document.createElement("div");
      wrap.className = "segment segment-user segment-" + (item.status === "failed" ? "failed" : "optimistic");
      wrap.dataset.stageKey = `retry-${item.id}`;
      wrap.dataset.stageSignature = ["retry", item.status, item.mode, detailSignature(item.prompt || "")].join("~");
      const sendingLabel = item.mode === "steer" ? "Steering current run..." : "Sending...";
      wrap.innerHTML = `
        <div class="user-bubble">${escapeHTML(item.prompt)}</div>
        <div class="message-meta">
          ${item.status === "failed"
            ? `<span>Error al enviar</span><button type="button" data-retry="${item.id}">Reintentar</button><button type="button" data-discard="${item.id}">Descartar</button>`
            : `<span>${sendingLabel}</span>`}
        </div>
      `;
      wrap.querySelector("[data-retry]")?.addEventListener("click", () => retryPending(item.id));
      wrap.querySelector("[data-discard]")?.addEventListener("click", () => dropPending(item.id));
      return wrap;
    }

    function renderAssistantTurn(turn, options = {}) {
      const wrap = document.createElement("div");
      wrap.className = "segment segment-assistant";
      wrap.dataset.stageKey = `assistant-${turn.id}`;
      wrap.dataset.stageSignature = assistantTurnSignature(turn, options);
      const entries = normalizeActivityEntries(turn.assistantEntries);
      if (!entries.length) return null;
      const finalEntry = latestFinalEntry(entries);
      const primaryIssue = entries.find((e) => e.kind === "error" || e.kind === "warning") || null;
      const timelineEntries = entries.filter(timelineEntryShouldRender);
      const primaryKind = primaryIssue?.kind === "error"
        ? "error"
        : primaryIssue?.kind === "warning"
          ? "warning"
          : finalEntry
            ? "final"
            : options.isBusy
              ? "working"
              : "pending";
      const block = document.createElement("div");
      block.className = `assistant-block is-${primaryKind}`;
      block.innerHTML = `
        <div class="assistant-block-header">
          <img class="assistant-avatar" src="/app-icon.png" alt="" aria-hidden="true">
          <div class="assistant-header-copy">
            <strong class="assistant-title">Codex</strong>
            <div class="assistant-meta">
              <span>${escapeHTML(primaryStatusLabel({ finalEntry, primaryIssue, isBusy: options.isBusy }))}</span>
              ${(finalEntry || primaryIssue)?.createdAt ? `<span>· ${timeShort(new Date((finalEntry || primaryIssue).createdAt))}</span>` : ""}
            </div>
          </div>
        </div>
      `;

      const body = document.createElement("div");
      body.className = "assistant-body";
      const timeline = document.createElement("div");
      timeline.className = "assistant-timeline";
      const displayItems = buildDisplayTimeline(timelineEntries);
      for (let index = 0; index < displayItems.length; index += 1) {
        const item = displayItems[index];
        const node = item.type === "artifact-group"
          ? renderArtifactGroupEntry(item.entries, { turnID: turn.id, index })
          : renderAssistantTimelineEntry(item.entry, { turnID: turn.id, index });
        if (node) timeline.appendChild(node);
      }
      if (!timeline.children.length && options.isBusy) {
        const waiting = document.createElement("div");
        waiting.className = "assistant-response is-streaming-preview";
        waiting.innerHTML = `<div class="assistant-inline-status">Codex sigue trabajando…</div>`;
        timeline.appendChild(waiting);
      }
      if (timeline.children.length) body.appendChild(timeline);

      block.appendChild(body);
      wrap.appendChild(block);
      attachPersistentDisclosures(wrap);
      attachApprovalActions(wrap);
      return wrap;
    }

    function assistantTurnSignature(turn, options = {}) {
      return [
        "assistant",
        turn.id || "",
        options.isBusy ? "busy" : "idle",
        activitySignature(turn.assistantEntries || []),
      ].join("~");
    }

    function buildDisplayTimeline(entries) {
      const out = [];
      let artifactRun = [];
      const flushArtifacts = () => {
        if (!artifactRun.length) return;
        if (artifactRun.length === 1) out.push({ type: "entry", entry: artifactRun[0] });
        else out.push({ type: "artifact-group", entries: artifactRun });
        artifactRun = [];
      };
      for (const entry of entries || []) {
        if (timelineEntryIsArtifact(entry)) {
          artifactRun.push(entry);
        } else {
          flushArtifacts();
          out.push({ type: "entry", entry });
        }
      }
      flushArtifacts();
      return out;
    }

    function timelineEntryIsArtifact(entry) {
      if (!entry || isApprovalRequestEntry(entry)) return false;
      if (entry.kind === "error" || entry.kind === "warning") return false;
      const blockKind = entry.blockKind || "";
      return ["command", "patch", "tool"].includes(blockKind) || !!entry.command;
    }

    function timelineEntryShouldRender(entry) {
      if (!entry) return false;
      if (isRoutineSystemEntry(entry)) return false;
      if (isApprovalRequestEntry(entry)) return true;
      if (entry.kind === "error" || entry.kind === "warning") return true;
      const blockKind = entry.blockKind || "";
      if (blockKind === "reasoning") return reasoningEntryHasUsefulContent(entry);
      if (blockKind === "final") return !!(entry.detail || "").trim();
      if (["command", "patch", "tool"].includes(blockKind)) {
        return !!((entry.detail || entry.command || entry.title || "").trim()) || (entry.relatedFiles || []).length > 0;
      }
      if ((blockKind || entry.kind) === "system") return !!(entry.detail || entry.title || "").trim();
      return !!(entry.detail || entry.title || "").trim();
    }

    function renderAssistantTimelineEntry(entry, context = {}) {
      if (isApprovalRequestEntry(entry)) return renderTimelineTextEntry(entry, "approval", context);
      const blockKind = entry.blockKind || "";
      if (["command", "patch", "tool"].includes(blockKind) || entry.command) {
        return renderTimelineArtifactEntry(entry, context);
      }
      return renderTimelineTextEntry(entry, timelineClassForEntry(entry), context);
    }

    function renderTimelineTextEntry(entry, className, context = {}) {
      const detail = renderEntryDetail(entry);
      if (!detail.trim()) return null;
      const item = document.createElement("div");
      item.className = `assistant-timeline-item assistant-timeline-text is-${className}`;
      const timelineKey = timelineKeyForEntry(entry, context);
      const speechText = speechTextForEntry(entry);
      const canSpeak = !!speechText && entry.blockKind === "final" && className === "final";
      item.dataset.timelineKey = timelineKey;
      item.dataset.timelineSignature = timelineSignatureForEntry(entry);
      if (canSpeak) {
        item.dataset.speakKey = timelineKey;
        item.dataset.speakText = speechText;
        item.classList.toggle("is-speaking", state.speech.activeKey === timelineKey);
        item.classList.toggle("is-paused", state.speech.activeKey === timelineKey && state.speech.paused);
      }
      const label = timelineLabelForEntry(entry);
      item.innerHTML = `
        ${label ? `<div class="assistant-timeline-label">${escapeHTML(label)}</div>` : ""}
        ${canSpeak ? renderSpeechActionsHTML(timelineKey) : ""}
        <div class="assistant-response ${entry.kind === "error" ? "is-error" : entry.kind === "warning" ? "is-warning" : ""}">${detail}</div>
      `;
      return item;
    }

    function renderTimelineArtifactEntry(entry, context = {}) {
      const bodyHTML = renderArtifactEntry(entry);
      const filesNode = renderRelatedFilesNode(entry.relatedFiles || []);
      if (!bodyHTML.trim() && !filesNode) return null;
      const details = document.createElement("details");
      details.className = `activity-collapsible assistant-process assistant-timeline-action is-${timelineClassForEntry(entry)}`;
      details.dataset.timelineKey = timelineKeyForEntry(entry, context);
      details.dataset.timelineSignature = timelineSignatureForEntry(entry);
      details.dataset.disclosureId = disclosureIDForEntry(entry, `timeline-${context.turnID || "turn"}-${context.index || 0}`);
      const summary = document.createElement("summary");
      summary.textContent = artifactTimelineSummary(entry);
      details.appendChild(summary);
      const body = document.createElement("div");
      body.className = "activity-collapsible-body assistant-process-body";
      if (bodyHTML.trim()) {
        const content = document.createElement("div");
        content.className = "assistant-support-item";
        content.innerHTML = bodyHTML;
        body.appendChild(content);
      }
      if (filesNode) body.appendChild(filesNode);
      details.appendChild(body);
      return details;
    }

    function renderArtifactGroupEntry(entries, context = {}) {
      const visibleEntries = (entries || []).filter((entry) => {
        const bodyHTML = renderArtifactEntry(entry);
        return bodyHTML.trim() || (entry.relatedFiles || []).length;
      });
      if (!visibleEntries.length) return null;

      const details = document.createElement("details");
      details.className = "activity-collapsible assistant-process assistant-timeline-action assistant-process-group";
      details.dataset.timelineKey = artifactGroupDisclosureID(visibleEntries, context);
      details.dataset.timelineSignature = visibleEntries.map(timelineSignatureForEntry).join("|");
      details.dataset.disclosureId = artifactGroupDisclosureID(visibleEntries, context);
      const summary = document.createElement("summary");
      summary.textContent = artifactGroupSummary(visibleEntries);
      details.appendChild(summary);

      const body = document.createElement("div");
      body.className = "activity-collapsible-body assistant-process-body assistant-process-group-body";
      for (const entry of visibleEntries) {
        const row = document.createElement("div");
        row.className = `assistant-process-row is-${timelineClassForEntry(entry)}`;
        const title = document.createElement("div");
        title.className = "assistant-process-row-title";
        title.textContent = artifactTimelineSummary(entry);
        row.appendChild(title);

        const bodyHTML = renderArtifactEntry(entry);
        const filesNode = renderRelatedFilesNode(entry.relatedFiles || []);
        if (bodyHTML.trim() || filesNode) {
          const content = document.createElement("div");
          content.className = "assistant-process-row-content";
          if (bodyHTML.trim()) content.innerHTML = bodyHTML;
          if (filesNode) content.appendChild(filesNode);
          row.appendChild(content);
        }
        body.appendChild(row);
      }
      details.appendChild(body);
      return details;
    }

    function artifactGroupDisclosureID(entries, context = {}) {
      const first = entries[0]?.id || entries[0]?.sourceID || "first";
      const last = entries[entries.length - 1]?.id || entries[entries.length - 1]?.sourceID || "last";
      return `artifact-group-${context.turnID || "turn"}-${context.index || 0}-${first}-${last}`
        .replace(/[^a-z0-9_-]+/gi, "-")
        .slice(0, 120);
    }

    function timelineKeyForEntry(entry, context = {}) {
      const raw = entry?.id || entry?.sourceID || entry?.groupID || `${context.turnID || "turn"}-${context.index || 0}`;
      return `timeline-${String(raw).replace(/[^a-z0-9_-]+/gi, "-").slice(0, 96)}`;
    }

    function timelineSignatureForEntry(entry) {
      return [
        entry?.id || "",
        entry?.sourceID || "",
        entry?.groupID || "",
        entry?.kind || "",
        entry?.blockKind || "",
        entry?.title || "",
        entry?.command || "",
        detailSignature(entry?.detail || ""),
        relatedFilesSignature(entry?.relatedFiles || [])
      ].join("::");
    }

    function artifactGroupSummary(entries) {
      const counts = entries.reduce((acc, entry) => {
        const kind = entry.blockKind === "command" || entry.command ? "cmd"
          : entry.blockKind === "patch" || looksLikeDiff(entry.detail) ? "patch"
            : "tool";
        acc[kind] = (acc[kind] || 0) + 1;
        for (const file of entry.relatedFiles || []) {
          const path = typeof file === "string" ? file : file?.path;
          if (path) acc.files.add(path);
        }
        return acc;
      }, { cmd: 0, tool: 0, patch: 0, files: new Set() });
      const parts = [];
      if (counts.cmd) parts.push(`${counts.cmd} cmd`);
      if (counts.tool) parts.push(`${counts.tool} tool`);
      if (counts.patch) parts.push(`${counts.patch} patch`);
      if (counts.files.size) parts.push(`${counts.files.size} file`);
      return `Ejecución · ${entries.length} acciones${parts.length ? ` · ${parts.join(" · ")}` : ""}`;
    }

    function timelineClassForEntry(entry) {
      if (entry.kind === "error") return "error";
      if (entry.kind === "warning") return "warning";
      const kind = entry.blockKind || entry.kind || "system";
      if (["final", "reasoning", "command", "patch", "tool", "system"].includes(kind)) return kind;
      return "system";
    }

    function timelineLabelForEntry(entry) {
      if (entry.kind === "error") return entry.title || "Error";
      if (entry.kind === "warning") return entry.title || "Aviso";
      if (isApprovalRequestEntry(entry)) return "Aprobación";
      if (entry.blockKind === "final") return "";
      if (entry.blockKind === "reasoning") {
        const title = String(entry.title || "").trim();
        if (/plan/i.test(title)) return "Plan";
        if (/summary|reasoning|thinking/i.test(title)) return "Pensando";
        return title || "Pensando";
      }
      if ((entry.blockKind || entry.kind) === "system") return entry.title || "Sistema";
      return entry.title || "";
    }

    function artifactTimelineSummary(entry) {
      if (entry.blockKind === "command" || entry.command) {
        const command = String(entry.command || "").trim().split("\n")[0] || "";
        return command ? `Comando · ${compactText(command, 96, 72, 16)}` : (entry.title || "Comando");
      }
      if (entry.blockKind === "patch" || looksLikeDiff(entry.detail)) {
        const files = (entry.relatedFiles || []).length;
        return files ? `Editando · ${files} archivo${files === 1 ? "" : "s"}` : (entry.title || "Editando archivos");
      }
      if (entry.blockKind === "tool") return entry.title || "Herramienta";
      return entry.title || displayTitleForEntry(entry);
    }

    function renderRelatedFilesNode(files) {
      const list = document.createElement("div");
      list.className = "related-files";
      for (const f of files || []) {
        const path = typeof f === "string" ? f : ((f && (f.path || f.relativePath || f.displayName)) || "");
        if (!path) continue;
        const a = document.createElement("a");
        a.className = "file-card";
        const ext = (path.split(".").pop() || "").toUpperCase().slice(0, 4);
        a.innerHTML = `<span class="file-card-icon">${escapeHTML(ext)}</span><span>${escapeHTML(shortPath(path))}</span>`;
        a.href = `/preview?path=${encodeURIComponent(path)}`;
        a.target = "_blank";
        a.rel = "noopener";
        list.appendChild(a);
      }
      return list.children.length ? list : null;
    }

    function latestFinalEntry(entries) {
      const finals = entries.filter((e) => e.blockKind === "final" && (e.detail || "").trim());
      return finals.length ? finals[finals.length - 1] : null;
    }

    function primaryStatusLabel({ finalEntry, primaryIssue, isBusy }) {
      if (primaryIssue?.kind === "error") return "Error";
      if (primaryIssue?.kind === "warning") return "Aviso";
      if (finalEntry) return "Respuesta";
      if (isBusy) return "Pensando";
      return "Actividad";
    }

    function renderArtifactEntry(entry) {
      if (entry.blockKind === "command" || entry.command) return renderCommandEntry(entry);
      if (entry.blockKind === "patch" || looksLikeDiff(entry.detail)) return renderPatchEntry(entry);
      if (entry.blockKind === "tool") return renderToolEntry(entry);
      return renderEntryDetail(entry);
    }

    function attachPersistentDisclosures(root) {
      root.querySelectorAll("details[data-disclosure-id]").forEach((details) => {
        const id = details.dataset.disclosureId;
        const fallback = details.hasAttribute("open");
        details.open = disclosureOpen(id, fallback);
        details.addEventListener("toggle", () => {
          setDisclosureOpen(id, details.open);
        });
      });
    }

    function disclosureOpen(id, fallback = false) {
      if (!id) return fallback;
      if (Object.prototype.hasOwnProperty.call(state.disclosureState, id)) {
        return !!state.disclosureState[id];
      }
      return fallback;
    }

    function setDisclosureOpen(id, open) {
      if (!id) return;
      state.disclosureState[id] = !!open;
      saveJSON(STORAGE.disclosureState, state.disclosureState);
    }

    function pickPrimaryEntry(entries) {
      return entries.find((e) => e.blockKind === "final" && (e.detail || "").trim())
        || entries.find((e) => e.blockKind === "patch")
        || entries.find((e) => e.blockKind === "command")
        || entries.find((e) => e.kind === "error")
        || entries.find((e) => e.kind === "warning")
        || entries[entries.length - 1];
    }

    function displayTitleForEntry(entry) {
      const kind = entry.blockKind || entry.kind;
      if (kind === "final") return "Respuesta de Codex";
      if (kind === "reasoning") return "Pensamiento visible";
      if (kind === "command") return "Comando";
      if (kind === "patch") return "Cambios en archivos";
      if (kind === "tool") return "Herramienta";
      if (entry.kind === "error") return "Error";
      if (entry.kind === "warning") return "Aviso";
      return entry.title || titleForKind(kind);
    }

    function reasoningSummaryLabel(entries) {
      const chars = entries.reduce((sum, e) => sum + ((e.detail || "").trim().length), 0);
      const suffix = chars > 800 ? ` · ${Math.round(chars / 1000)}k chars` : "";
      return `Razonamiento (${entries.length}${suffix})`;
    }

    function renderEntryDetail(entry) {
      const style = entry.detailStyle || "body";
      if (isApprovalRequestEntry(entry)) {
        return renderApprovalRequest(entry);
      }
      if (entry.blockKind === "command" || entry.command) {
        return renderCommandEntry(entry);
      }
      if (entry.blockKind === "final") {
        return renderMarkdown(entry.detail || "");
      }
      if (entry.blockKind === "reasoning") {
        return renderMarkdown(compactText(entry.detail || "", 4_800, 3_200, 1_100));
      }
      if (entry.blockKind === "patch" || looksLikeDiff(entry.detail)) {
        return renderPatchEntry(entry);
      }
      if (entry.blockKind === "tool") {
        return renderToolEntry(entry);
      }
      if (entry.kind === "error" || entry.kind === "warning") {
        return `<p>${escapeHTML(entry.detail || entry.title || "").replace(/\n/g, "<br>")}</p>`;
      }
      if (style === "markdown") return renderMarkdown(entry.detail || "");
      if (style === "code") return renderCodeBlockWrapper(entry.detail || "", "plain");
      if (style === "body") return renderMarkdown(entry.detail || entry.title || "");
      if (style === "monospaced") return renderCollapsibleCode("Detalle técnico", entry.detail || "", { open: false, maxCharacters: 6_000 });
      if (style === "plain") return `<p>${escapeHTML(entry.detail || entry.title || "").replace(/\n/g, "<br>")}</p>`;
      return `<p>${escapeHTML(entry.detail || "")}</p>`;
    }

    function isApprovalRequestEntry(entry) {
      return /^approval-request-\d+$/.test(String(entry?.sourceID || "")) ||
        /Approval Requested/i.test(String(entry?.title || ""));
    }

    function approvalRequestID(entry) {
      const source = String(entry?.sourceID || "");
      const fromSource = source.match(/^approval-request-(\d+)$/);
      if (fromSource) return fromSource[1];
      const detail = String(entry?.detail || "");
      const fromDetail = detail.match(/Request ID:\s*(\d+)/i);
      return fromDetail ? fromDetail[1] : "";
    }

    function renderApprovalRequest(entry) {
      const requestID = approvalRequestID(entry);
      const detail = entry.detail || entry.title || "Codex is waiting for approval.";
      const canAct = !!requestID && state.sessionDetail?.session?.isBusy;
      return `
        <div class="approval-card" data-approval-id="${escapeHTML(requestID)}">
          <div class="approval-card-title">
            <span class="live-dot" aria-hidden="true"></span>
            <span>Codex espera aprobación</span>
          </div>
          <div class="approval-card-detail">${escapeHTML(detail)}</div>
          <div class="approval-actions">
            <button class="approval-action primary" type="button" data-approval-decision="accept"${canAct ? "" : " disabled"}>Aprobar una vez</button>
            <button class="approval-action" type="button" data-approval-decision="acceptForSession"${canAct ? "" : " disabled"}>Aprobar sesión</button>
            <button class="approval-action danger" type="button" data-approval-decision="decline"${canAct ? "" : " disabled"}>Rechazar</button>
          </div>
        </div>
      `;
    }

    function attachApprovalActions(root) {
      root.querySelectorAll("[data-approval-decision]").forEach((button) => {
        button.addEventListener("click", async () => {
          const card = button.closest("[data-approval-id]");
          const requestID = card?.dataset.approvalId;
          const decision = button.dataset.approvalDecision;
          if (!requestID || !decision) return;
          await resolveApprovalRequest(requestID, decision);
        });
      });
    }

    async function resolveApprovalRequest(requestID, decision) {
      const sessionID = state.selectedSessionId;
      if (!sessionID) return;
      try {
        const localSessionId = await ensureLocalSessionID(sessionID);
        const detail = await api(`/api/sessions/${localSessionId}/approvals/${encodeURIComponent(requestID)}`, {
          method: "POST",
          json: { decision },
        });
        onSessionDetailTick(detail);
        toast(decision === "decline" ? "Aprobación rechazada" : "Aprobado", decision === "decline" ? "info" : "success", 1400);
      } catch (err) {
        toast(err?.message || "No se pudo responder a la aprobación", "error");
      }
    }

    function renderCommandEntry(entry) {
      const cmd = entry.command || "";
      const parsed = splitCommandDetail(entry.detail || "");
      const parts = [];
      if (cmd) parts.push(`<div class="command-block">${escapeHTML(cmd)}</div>`);
      if (parsed.status) parts.push(`<div class="activity-summary-row">${escapeHTML(parsed.status)}</div>`);
      if (parsed.output) {
        parts.push(renderCollapsibleCode(`Salida del comando · ${lineCount(parsed.output)} líneas`, parsed.output, {
          open: false,
          className: "command-output",
          maxCharacters: 7_000,
          disclosureID: disclosureIDForEntry(entry, "command-output")
        }));
      }
      if (!cmd && !parsed.output && entry.detail) {
        parts.push(renderCollapsibleCode("Detalle del comando", entry.detail, {
          open: false,
          maxCharacters: 5_000,
          disclosureID: disclosureIDForEntry(entry, "command-detail")
        }));
      }
      return parts.join("");
    }

    function splitCommandDetail(detail) {
      const text = (detail || "").trim();
      if (!text || /^Live output will appear/i.test(text) || /^Command started/i.test(text)) {
        return { status: "", output: "" };
      }
      const match = text.match(/^(Exit code \d+|Completed)(?:\n\n([\s\S]*))?$/);
      if (match) return { status: match[1], output: match[2] || "" };
      return { status: "", output: text };
    }

    function renderPatchEntry(entry) {
      const text = entry.detail || "";
      if (!text.trim()) return "";
      const open = lineCount(text) <= 32 && text.length <= 3_500;
      return renderDisclosureHTML(
        disclosureIDForEntry(entry, "patch"),
        `Diff y cambios · ${lineCount(text)} líneas`,
        looksLikeDiff(text) ? renderDiff(compactText(text, 9_000, 5_000, 2_500)) : renderMarkdown(text),
        { open }
      );
    }

    function renderToolEntry(entry) {
      const detail = (entry.detail || "").trim();
      if (!detail) return "";
      const lines = detail.split("\n");
      const first = lines.shift() || entry.title || "Herramienta";
      const rest = lines.join("\n").trim();
      const parts = [`<div class="activity-summary-row">${escapeHTML(compactText(first, 260, 180, 60))}</div>`];
      if (rest) {
        parts.push(renderCollapsibleCode(`Resultado · ${lineCount(rest)} líneas`, rest, {
          open: false,
          maxCharacters: 5_500,
          disclosureID: disclosureIDForEntry(entry, "tool-result")
        }));
      }
      return parts.join("");
    }

    function renderCollapsibleCode(summary, text, options = {}) {
      const raw = text || "";
      const maxCharacters = options.maxCharacters || 6_000;
      const compact = compactText(raw, maxCharacters, Math.floor(maxCharacters * 0.58), Math.floor(maxCharacters * 0.24));
      const omitted = compact !== raw ? `<div class="activity-hidden-note">Salida recortada para no saturar el chat. Abre la sesión completa si necesitas todo el log.</div>` : "";
      return renderDisclosureHTML(
        options.disclosureID || null,
        summary,
        `<div class="command-block ${escapeHTML(options.className || "")}">${escapeHTML(compact)}</div>${omitted}`,
        { open: options.open, className: "activity-collapsible" }
      );
    }

    function renderDisclosureHTML(id, summary, bodyHTML, options = {}) {
      const disclosureID = id || `disclosure-${Math.random().toString(36).slice(2)}`;
      const openAttr = options.open ? " open" : "";
      const className = options.className || "activity-collapsible";
      return `<details class="${escapeHTML(className)}" data-disclosure-id="${escapeHTML(disclosureID)}"${openAttr}><summary>${escapeHTML(summary)}</summary><div class="activity-collapsible-body">${bodyHTML}</div></details>`;
    }

    function disclosureIDForEntry(entry, prefix) {
      const raw = entry?.id || entry?.sourceID || entry?.groupID || entry?.title || prefix || "item";
      return `${prefix}-${String(raw).replace(/[^a-z0-9_-]+/gi, "-").slice(0, 80)}`;
    }

    function compactText(text, maxCharacters = 6_000, headCharacters = 3_500, tailCharacters = 1_500) {
      const raw = String(text || "");
      if (raw.length <= maxCharacters) return raw;
      const head = raw.slice(0, headCharacters);
      const tail = raw.slice(Math.max(headCharacters, raw.length - tailCharacters));
      const omitted = raw.length - head.length - tail.length;
      return `${head}\n\n… ${omitted.toLocaleString()} caracteres omitidos …\n\n${tail}`;
    }

    function lineCount(text) {
      if (!text) return 0;
      return String(text).split("\n").length;
    }

    function looksLikeDiff(text) {
      if (!text) return false;
      const lines = text.split("\n");
      let hits = 0;
      for (const l of lines.slice(0, 40)) {
        if (/^(?:diff --git|@@|\+\+\+|---|[+-])/.test(l)) hits++;
      }
      return hits >= 3;
    }

    function renderDiff(text) {
      const lines = text.split("\n");
      const body = lines.map((line) => {
        let cls = "";
        let gutter = "";
        if (line.startsWith("+++") || line.startsWith("---") || line.startsWith("diff --git")) {
          cls = "diff-hunk"; gutter = "~";
        } else if (line.startsWith("@@")) {
          cls = "diff-hunk"; gutter = "@";
        } else if (line.startsWith("+")) {
          cls = "diff-add"; gutter = "+";
        } else if (line.startsWith("-")) {
          cls = "diff-del"; gutter = "-";
        } else {
          gutter = " ";
        }
        return `<div class="diff-line ${cls}"><span class="diff-gutter">${gutter}</span><span>${escapeHTML(line)}</span></div>`;
      }).join("");
      return `<div class="diff-block"><div class="diff-head">Patch</div><div class="diff-body">${body}</div></div>`;
    }

    function renderThinking(detail) {
      const el = document.createElement("div");
      el.className = "thinking";
      const live = liveSnapshotFromDetail(detail);
      const label = live?.activeTitle || live?.label || "Codex está trabajando";
      const detailText = live?.activeDetail || live?.detail || "";
      el.dataset.stageKey = `thinking-${detail?.session?.id || state.selectedSessionId || "current"}`;
      el.dataset.stageSignature = ["thinking", live?.state || "", label, detailSignature(detailText || "")].join("~");
      el.innerHTML = `
        <span class="thinking-dots" aria-hidden="true"><span></span><span></span><span></span></span>
        <span>${escapeHTML(label)}${detailText ? ` · ${escapeHTML(compactInline(detailText, 90))}` : ""}</span>
      `;
      return el;
    }

    function compactInline(text, max = 120) {
      const raw = String(text || "").replace(/\s+/g, " ").trim();
      if (raw.length <= max) return raw;
      return raw.slice(0, Math.max(0, max - 1)).trimEnd() + "…";
    }

    function titleForKind(kind) {
      switch (kind) {
        case "reasoning": return "Razonamiento";
        case "command": return "Comando";
        case "patch": return "Parche";
        case "final": return "Respuesta";
        case "tool": return "Herramienta";
        case "system": return "Sistema";
        default: return "Mensaje";
      }
    }

    function blockKindLabel(kind) {
      switch (kind) {
        case "reasoning": return "razona";
        case "command": return "ejecuta";
        case "patch": return "patch";
        case "final": return "final";
        case "tool": return "tool";
        case "system": return "system";
        case "assistant": return "asistente";
        default: return kind || "bloque";
      }
    }

    function uniqueFiles(entries) {
      const out = [];
      const seen = new Set();
      for (const e of entries) {
        for (const f of e.relatedFiles || []) {
          const path = typeof f === "string" ? f : (f && (f.path || f.relativePath || f.displayName)) || "";
          if (!path || seen.has(path)) continue;
          seen.add(path);
          out.push(path);
        }
      }
      return out.slice(0, 10);
    }

    function handleStreamScroll() {
      const { scrollTop, scrollHeight, clientHeight } = els.chatStream;
      const distanceFromBottom = scrollHeight - scrollTop - clientHeight;
      state.pinnedToBottom = distanceFromBottom < 120;
      if (state.pinnedToBottom) state.unseenAssistantCount = 0;
      updateScrollBottomButton();
    }

    function scrollToBottom(behavior = "auto") {
      els.chatStream.scrollTo({ top: els.chatStream.scrollHeight, behavior: PREFERS_REDUCED_MOTION ? "auto" : behavior });
    }

    function updateScrollBottomButton() {
      const hide = state.pinnedToBottom;
      els.scrollBottom.hidden = hide;
      if (state.unseenAssistantCount > 0 && !hide) {
        els.scrollBottomBadge.hidden = false;
        els.scrollBottomBadge.textContent = String(state.unseenAssistantCount);
      } else {
        els.scrollBottomBadge.hidden = true;
      }
    }

    // ===== Server-Sent Events with polling fallback =====
    function startSessionsStream() {
      const workspaceID = state.selectedWorkspaceId || "";
      if (state.sessionsSseController && state.sessionsStreamWorkspaceId === workspaceID) return;
      if (state.sessionsSseController) {
        try { state.sessionsSseController.close(); } catch {}
        state.sessionsSseController = null;
      }
      state.sessionsStreamWorkspaceId = workspaceID;
      const url = workspaceID ? `/api/sessions/stream?workspaceID=${encodeURIComponent(workspaceID)}` : "/api/sessions/stream";
      try {
        const es = new EventSource(url);
        es.addEventListener("sessions", (event) => {
          try {
            const sessions = JSON.parse(event.data) || [];
            applyLiveSessions(sessions);
            renderConnection("ok");
          } catch {}
        });
        es.addEventListener("reconnect", () => {
          es.close();
          state.sessionsSseController = null;
          setTimeout(startSessionsStream, 250);
        });
        es.addEventListener("error", () => {
          es.close();
          state.sessionsSseController = null;
          setTimeout(() => {
            refreshAll().catch(() => {});
            startSessionsStream();
          }, 1600);
        });
        state.sessionsSseController = { close: () => es.close() };
      } catch {
        state.sessionsSseController = null;
      }
    }

    function applyLiveSessions(sessions) {
      const previousSelected = state.selectedSessionId;
      state.sessions = sessions || [];
      if (previousSelected && !findSession(previousSelected)) {
        state.selectedSessionId = state.sessions[0]?.id || null;
        if (state.selectedSessionId) localStorage.setItem(STORAGE.session, state.selectedSessionId);
        else localStorage.removeItem(STORAGE.session);
        renderStageForCurrent().catch((err) => console.warn("[miwhisper] live session selection failed", err));
      }
      renderSessions();
      updateTopbar();
    }

    function startSessionStream(sessionID) {
      stopSessionStream();
      if (!sessionID) return;
      state.streamLastEventAt = Date.now();
      const es = tryOpenEventSource(sessionID);
      if (!es) {
        startPolling(sessionID);
        return;
      }
      state.sseActiveSessionId = sessionID;
      let errorStreak = 0;
      es.addEventListener("session", (event) => {
        try {
          const detail = JSON.parse(event.data);
          state.streamLastEventAt = Date.now();
          onSessionDetailTick(detail);
          errorStreak = 0;
        } catch {}
      });
      es.addEventListener("reconnect", () => {
        es.close();
        startSessionStream(sessionID);
      });
      es.addEventListener("error", () => {
        errorStreak++;
        if (errorStreak >= 2 && state.sseActiveSessionId === sessionID) {
          console.warn("[miwhisper] SSE degraded, falling back to polling");
          es.close();
          state.sseController = null;
          startPolling(sessionID);
        }
      });
      state.sseController = { close: () => es.close() };
      startStreamWatchdog(sessionID);
    }

    function tryOpenEventSource(sessionID) {
      try {
        return new EventSource(`/api/sessions/${sessionID}/stream`);
      } catch {
        return null;
      }
    }

    function stopSessionStream() {
      if (state.sseController) { try { state.sseController.close(); } catch {} state.sseController = null; }
      state.sseActiveSessionId = null;
      if (state.pollingHandle) { clearTimeout(state.pollingHandle); state.pollingHandle = null; }
      if (state.streamWatchdogHandle) { clearInterval(state.streamWatchdogHandle); state.streamWatchdogHandle = null; }
      state.streamLastEventAt = 0;
      state.streamRecoveryInFlight = false;
    }

    function startPolling(sessionID) {
      if (state.pollingHandle) clearTimeout(state.pollingHandle);
      const tick = async () => {
        if (state.selectedSessionId !== sessionID) return;
        try {
          const detail = await api(`/api/sessions/${sessionID}`);
          onSessionDetailTick(detail);
          state.pollingTickMs = detail.session?.isBusy ? 700 : 1800;
          renderConnection("ok");
        } catch (err) {
          state.pollingTickMs = Math.min(state.pollingTickMs * 1.6, 10_000);
          renderConnection("warn", "Reconectando…");
        }
        state.pollingHandle = setTimeout(tick, state.pollingTickMs);
      };
      state.pollingHandle = setTimeout(tick, 300);
    }

    function schedulePollingFallback() {
      if (!state.selectedSessionId) return;
      if (state.pollingHandle) return;
      state.pollingHandle = setTimeout(() => {
        state.pollingHandle = null;
        if (state.selectedSessionId) startPolling(state.selectedSessionId);
      }, 2500);
    }

    function startStreamWatchdog(sessionID) {
      if (state.streamWatchdogHandle) clearInterval(state.streamWatchdogHandle);
      state.streamWatchdogHandle = setInterval(() => {
        if (!sessionID || state.selectedSessionId !== sessionID) return;
        const detail = state.sessionDetail;
        if (!detail?.session?.isBusy) return;
        const lastTick = state.streamLastEventAt || 0;
        if (!lastTick) return;
        if (Date.now() - lastTick < 9000) return;
        recoverSelectedSessionConnection("stalled", { restartStream: true, silent: true });
      }, 4000);
    }

    async function recoverSelectedSessionConnection(reason, options = {}) {
      const sessionID = state.selectedSessionId;
      if (!sessionID || state.streamRecoveryInFlight) return;
      state.streamRecoveryInFlight = true;
      try {
        const localSessionId = await ensureLocalSessionID(sessionID);
        const detail = await api(`/api/sessions/${localSessionId}`);
        state.streamLastEventAt = Date.now();
        onSessionDetailTick(detail);
        if (options.restartStream !== false) {
          stopSessionStream();
          startSessionStream(localSessionId);
        }
        if (!options.silent) renderConnection("ok", "Sesión resincronizada");
      } catch (err) {
        console.warn("[miwhisper] stream recovery failed", reason, err);
        if (!options.silent) renderConnection("warn", "Reconectando la conversación…");
        schedulePollingFallback();
      } finally {
        state.streamRecoveryInFlight = false;
      }
    }

    function onSessionDetailTick(detail) {
      if (!detail?.session) return;
      if (!sessionMatchesID(detail.session, state.selectedSessionId)) return;
      if (detail.session.id && detail.session.id !== state.selectedSessionId) {
        state.selectedSessionId = detail.session.id;
        localStorage.setItem(STORAGE.session, detail.session.id);
      }
      const prev = state.sessionDetail;
      state.sessionDetail = detail;
      syncNativeCarWatch(detail, { reason: "session-detail" });
      syncNativeCarCommandListening(detail, { reason: "session-detail" });
      // Update session list row updatedAt/isBusy
      const idx = state.sessions.findIndex((s) => (
        sessionMatchesID(s, detail.session.id) ||
        sessionMatchesID(s, detail.session.recordID) ||
        sessionMatchesID(s, detail.session.threadID)
      ));
      if (idx >= 0) {
        state.sessions[idx] = { ...state.sessions[idx], ...detail.session };
        renderSessions();
      }
      // Only re-render stage if something actually changed
      if (!sessionDetailEqual(prev, detail)) {
        // Count new assistant entries while user not at bottom / tab hidden
        if (prev) {
          const prevFinalCount = countFinalEntries(prev.activity, prev.session?.latestResponse || "");
          const nextFinalCount = countFinalEntries(detail.activity, detail.session?.latestResponse || "");
          const prevLiveState = prev.live?.state || "";
          const nextLiveState = detail.live?.state || "";
          if (nextLiveState && nextLiveState !== prevLiveState) {
            if (nextLiveState === "attention" || detail.live?.needsAttention) {
              notifyIfUseful("Codex necesita atención", detail.live?.label || detail.session.title || "MiWhisper Companion");
            } else if (nextLiveState === "error") {
              notifyIfUseful("Codex encontró un error", detail.live?.detail || detail.session.title || "MiWhisper Companion");
            }
          }
          if (nextFinalCount > prevFinalCount) {
            if (!state.pinnedToBottom || document.hidden) {
              state.unseenAssistantCount += nextFinalCount - prevFinalCount;
            }
            notifyIfUseful("Codex respondió", detail.session.title || "MiWhisper Companion");
          }
          maybeSpeakCarUpdate(prev, detail);
        }
        scheduleStageRender();
        updateTopbar();
        renderRuntimeControls();
        renderCarModePanel();
        renderFollowupQueue();
        // Drain retry queue successes
        pruneRetryQueueAgainstServer(detail);
        if (prev?.session?.isBusy && !detail.session.isBusy) {
          maybeDrainFollowupQueue(detail);
        }
      } else if (state.sessionDetail.session.isBusy !== prev?.session.isBusy) {
        updateTopbar();
        renderRuntimeControls();
        renderCarModePanel();
        renderFollowupQueue();
        if (prev?.session?.isBusy && !detail.session.isBusy) {
          maybeDrainFollowupQueue(detail);
        }
      }
    }

    function sessionDetailEqual(a, b) {
      if (!a || !b) return false;
      if (a.session.isBusy !== b.session.isBusy) return false;
      if ((a.session.latestResponse || "") !== (b.session.latestResponse || "")) return false;
      if (liveSignature(a.live) !== liveSignature(b.live)) return false;
      if ((a.activity || []).length !== (b.activity || []).length) return false;
      return activitySignature(a.activity || []) === activitySignature(b.activity || []);
    }

    function activitySignature(activity) {
      return (activity || [])
        .slice(-24)
        .map((entry) => [
          entry.id || "",
          entry.sourceID || "",
          entry.groupID || "",
          entry.kind || "",
          entry.blockKind || "",
          entry.title || "",
          entry.command || "",
          detailSignature(entry.detail || ""),
          relatedFilesSignature(entry.relatedFiles || [])
        ].join("::"))
        .join("|");
    }

    function detailSignature(text) {
      const raw = String(text || "").trim();
      if (!raw) return "";
      return `${raw.length}:${raw.slice(0, 80)}:${raw.slice(-180)}`;
    }

    function relatedFilesSignature(files) {
      return (files || []).map((f) => {
        if (typeof f === "string") return f;
        return f?.path || f?.relativePath || f?.displayName || "";
      }).filter(Boolean).slice(-12).join(",");
    }

    function liveSignature(live) {
      if (!live) return "";
      return [
        live.state || "",
        live.label || "",
        detailSignature(live.detail || ""),
        live.activeTitle || "",
        detailSignature(live.activeDetail || ""),
        live.latestKind || "",
        live.commandCount || 0,
        live.toolCount || 0,
        live.patchCount || 0,
        live.fileCount || 0,
        live.warningCount || 0,
        live.errorCount || 0,
        live.needsAttention ? "attention" : "",
      ].join("~");
    }

    function countFinalEntries(activity, latestResponse = "") {
      return ensureFinalActivity(activity || [], latestResponse)
        .filter((e) => e.blockKind === "final" && (e.detail || "").trim())
        .length;
    }

    // ===== Composer, sending, drafts =====
    function handleComposerKey(e) {
      if (!els.suggestionPopup.hidden) {
        if (e.key === "ArrowDown") { e.preventDefault(); moveSuggestion(1); return; }
        if (e.key === "ArrowUp") { e.preventDefault(); moveSuggestion(-1); return; }
        if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); acceptSuggestion(); return; }
        if (e.key === "Escape") { e.preventDefault(); hideSuggestions(); return; }
        if (e.key === "Tab") { e.preventDefault(); acceptSuggestion(); return; }
      }
      const isEnter = e.key === "Enter";
      if (isEnter && (e.metaKey || e.ctrlKey)) {
        e.preventDefault(); sendComposer(); return;
      }
      if (isEnter && !e.shiftKey && !e.isComposing && !IS_TOUCH) {
        e.preventDefault(); sendComposer(); return;
      }
    }

    function autoGrow() {
      els.composer.style.height = "auto";
      els.composer.style.height = Math.min(els.composer.scrollHeight, 200) + "px";
    }

    function draftKeyFor(sessionID) { return STORAGE.draftPrefix + (sessionID || "__new__"); }
    function saveDraft(sessionID, text) {
      try {
        if (text?.trim()) localStorage.setItem(draftKeyFor(sessionID), text);
        else localStorage.removeItem(draftKeyFor(sessionID));
      } catch {}
    }
    function loadDraft(sessionID) {
      try { return localStorage.getItem(draftKeyFor(sessionID)) || ""; } catch { return ""; }
    }
    function loadComposerDraft() {
      const draft = loadDraft(state.selectedSessionId);
      els.composer.value = draft;
      autoGrow();
    }

    async function handleImageFiles(fileList) {
      const files = Array.from(fileList || []).filter((file) => file.type.startsWith("image/"));
      if (!files.length) return;
      const room = Math.max(0, 4 - state.attachments.length);
      if (!room) {
        toast("Máximo 4 imágenes por turno", "warn");
        return;
      }
      for (const file of files.slice(0, room)) {
        if (file.size > 15 * 1024 * 1024) {
          toast(`${file.name} supera 15 MB`, "error");
          continue;
        }
        try {
          const dataURL = await readFileAsDataURL(file);
          state.attachments.push({
            id: "att-" + Math.random().toString(36).slice(2),
            name: file.name || "imagen",
            mimeType: file.type || "image/png",
            size: file.size || 0,
            dataURL,
          });
        } catch {
          toast(`No pude leer ${file.name || "la imagen"}`, "error");
        }
      }
      renderAttachments();
      renderRuntimeControls();
      vibrate(8);
    }

    function readFileAsDataURL(file) {
      return new Promise((resolve, reject) => {
        const reader = new FileReader();
        reader.onload = () => resolve(String(reader.result || ""));
        reader.onerror = () => reject(reader.error || new Error("No se pudo leer el archivo"));
        reader.readAsDataURL(file);
      });
    }

    function attachmentPayloads() {
      return state.attachments.map((item) => ({
        type: "local_image",
        name: item.name,
        mimeType: item.mimeType,
        dataURL: item.dataURL,
      }));
    }

    function clearAttachments() {
      state.attachments = [];
      renderAttachments();
      renderRuntimeControls();
    }

    function renderAttachments() {
      if (!els.attachmentTray) return;
      els.attachmentTray.hidden = state.attachments.length === 0;
      els.attachmentTray.innerHTML = "";
      for (const item of state.attachments) {
        const chip = document.createElement("div");
        chip.className = "attachment-chip";
        chip.innerHTML = `
          <img class="attachment-thumb" src="${escapeHTML(item.dataURL)}" alt="">
          <span class="attachment-name">${escapeHTML(item.name || "imagen")}</span>
          <button class="attachment-remove" type="button" aria-label="Quitar adjunto">×</button>
        `;
        chip.querySelector(".attachment-remove").addEventListener("click", () => {
          state.attachments = state.attachments.filter((att) => att.id !== item.id);
          renderAttachments();
          renderRuntimeControls();
        });
        els.attachmentTray.appendChild(chip);
      }
    }

    async function sendComposer() {
      const raw = els.composer.value;
      let text = raw.trim();
      const outgoingAttachments = attachmentPayloads();
      if (!text && outgoingAttachments.length) text = "Analiza la imagen adjunta.";
      if (!text) return;
      // Slash command actions
      if (text.startsWith("/")) {
        const cmd = SLASH_COMMANDS.find((c) => text === c.label || text.startsWith(c.label + " "));
        if (cmd?.action) {
          await handleSlashAction(cmd.action);
          els.composer.value = "";
          autoGrow();
          saveDraft(state.selectedSessionId, "");
          return;
        }
      }
      const activeSessionBusy = state.sessionDetail?.session?.isBusy === true && !!state.selectedSessionId;
      if (activeSessionBusy && state.runtimePrefs.queueMode === "queue") {
        const queuedText = applySubagentsMode(applyPlanMode(text));
        els.composer.value = "";
        autoGrow();
        saveDraft(state.selectedSessionId, "");
        enqueueFollowup(queuedText, outgoingAttachments, runtimeTurnParams());
        clearAttachments();
        if (state.runtimePrefs.planMode) {
          state.runtimePrefs.planMode = false;
          saveRuntimePrefs();
          renderRuntimeControls();
        }
        state.subagentsMode = false;
        renderRuntimeControls();
        return;
      }
      const preDraftKey = draftKeyFor(state.selectedSessionId);
      const optimisticID = "opt-" + Math.random().toString(36).slice(2);
      const outgoingText = applySubagentsMode(applyPlanMode(text));
      const optimistic = {
        id: optimisticID,
        sessionID: state.selectedSessionId,
        prompt: outgoingText,
        status: "sending",
        mode: activeSessionBusy ? "steer" : "send",
        createdAt: new Date().toISOString(),
        workspaceID: state.selectedWorkspaceId,
      };
      els.composer.value = "";
      autoGrow();
      state.retryQueue.push(optimistic);
      persistRetryQueue();
      renderStage();
      scrollToBottom("smooth");
      vibrate(12);

      try {
        if (state.selectedSessionId) {
          const localSessionId = await ensureLocalSessionID(state.selectedSessionId);
          if (localSessionId !== state.selectedSessionId) {
            state.selectedSessionId = localSessionId;
            optimistic.sessionID = localSessionId;
            localStorage.setItem(STORAGE.session, localSessionId);
          }
          const detail = await api(`/api/sessions/${localSessionId}/messages`, {
            method: "POST",
            json: {
              prompt: outgoingText,
              attachments: outgoingAttachments,
              ...runtimeTurnParams(),
            },
          });
          onSessionDetailTick(detail);
          startSessionStream(localSessionId);
        } else {
          const detail = await api("/api/sessions", {
            method: "POST",
            json: {
              prompt: outgoingText,
              workspaceID: state.selectedWorkspaceId,
              openWindow: false,
              attachments: outgoingAttachments,
              ...runtimeCreateSessionParams(),
            },
          });
          state.selectedSessionId = detail.session.id;
          localStorage.setItem(STORAGE.session, detail.session.id);
          state.sessionDetail = detail;
          syncNativeCarWatch(detail, { reason: "new-session" });
          syncNativeCarCommandListening(detail, { reason: "new-session" });
          await refreshAll();
          renderStage();
          startSessionStream(state.selectedSessionId);
        }
        dropPending(optimisticID);
        localStorage.removeItem(preDraftKey);
        if (state.runtimePrefs.planMode) {
          state.runtimePrefs.planMode = false;
          saveRuntimePrefs();
          renderRuntimeControls();
        }
        state.subagentsMode = false;
        clearAttachments();
        renderConnection("ok");
      } catch (err) {
        console.error("[miwhisper] send failed", err);
        markPendingFailed(optimisticID, err?.message || "Error de conexión");
        renderConnection("error", "No se pudo enviar");
        toast("No se pudo enviar. Pulsa Reintentar.", "error");
      }
    }

    function persistRetryQueue() {
      try { localStorage.setItem(STORAGE.retryQueue, JSON.stringify(state.retryQueue)); } catch {}
    }

    function persistFollowupQueue() {
      try { localStorage.setItem(STORAGE.followupQueue, JSON.stringify(state.followupQueue)); } catch {}
    }

    function queuedFollowupsForSelectedSession() {
      const sessionID = state.selectedSessionId;
      if (!sessionID) return [];
      return state.followupQueue.filter((item) => item.sessionID === sessionID);
    }

    function enqueueFollowup(prompt, attachments = [], runtime = {}) {
      const sessionID = state.selectedSessionId;
      if (!sessionID) return false;
      state.followupQueue.push({
        id: "queue-" + Math.random().toString(36).slice(2),
        sessionID,
        prompt,
        attachments,
        runtime,
        createdAt: new Date().toISOString(),
      });
      persistFollowupQueue();
      renderFollowupQueue();
      renderRuntimeControls();
      toast("Encolado para cuando termine la run", "success", 1600);
      return true;
    }

    function renderFollowupQueue() {
      if (!els.composerQueue) return;
      const queued = queuedFollowupsForSelectedSession();
      els.composerQueue.hidden = queued.length === 0;
      els.composerQueue.innerHTML = "";
      for (const item of queued.slice(0, 4)) {
        const row = document.createElement("div");
        row.className = "queue-row";
        row.innerHTML = `
          <div class="queue-copy">
            <div class="queue-label">En cola · ${item.attachments?.length ? `${item.attachments.length} img` : "texto"}</div>
            <div class="queue-text">${escapeHTML(item.prompt)}</div>
          </div>
          <div class="queue-actions">
            <button class="queue-action" type="button" data-act="restore">Restore</button>
            <button class="queue-action" type="button" data-act="remove">Remove</button>
          </div>
        `;
        row.querySelector('[data-act="restore"]').addEventListener("click", () => {
          els.composer.value = item.prompt;
          state.attachments = (item.attachments || []).map((att) => ({ ...att, id: "att-" + Math.random().toString(36).slice(2) }));
          removeFollowup(item.id);
          autoGrow();
          renderAttachments();
          els.composer.focus();
        });
        row.querySelector('[data-act="remove"]').addEventListener("click", () => removeFollowup(item.id));
        els.composerQueue.appendChild(row);
      }
      if (queued.length > 4) {
        const note = document.createElement("div");
        note.className = "queue-row";
        note.innerHTML = `<div class="queue-copy"><div class="queue-label">${queued.length - 4} more queued</div><div class="queue-text">They will send one by one as Codex becomes idle.</div></div>`;
        els.composerQueue.appendChild(note);
      }
    }

    function removeFollowup(id) {
      state.followupQueue = state.followupQueue.filter((item) => item.id !== id);
      persistFollowupQueue();
      renderFollowupQueue();
    }

    async function maybeDrainFollowupQueue(detail) {
      if (!detail?.session || detail.session.isBusy || state.queueDrainInFlight) return;
      const next = state.followupQueue.find((item) => sessionMatchesID(detail.session, item.sessionID));
      if (!next) return;
      state.queueDrainInFlight = true;
      try {
        removeFollowup(next.id);
        await api(`/api/sessions/${detail.session.id}/messages`, {
          method: "POST",
          json: {
            prompt: next.prompt,
            attachments: next.attachments || [],
            ...(next.runtime || {}),
          },
        });
        toast("Enviando siguiente prompt en cola", "success", 1300);
        await recoverSelectedSessionConnection("queue-drain", { restartStream: true, silent: true });
      } catch (err) {
        state.followupQueue.unshift(next);
        persistFollowupQueue();
        renderFollowupQueue();
        toast(err?.message || "No se pudo enviar la cola", "error");
      } finally {
        state.queueDrainInFlight = false;
      }
    }

    function markPendingFailed(id, message) {
      const item = state.retryQueue.find((r) => r.id === id);
      if (!item) return;
      item.status = "failed";
      item.error = message;
      persistRetryQueue();
      renderStage();
    }

    function dropPending(id) {
      state.retryQueue = state.retryQueue.filter((r) => r.id !== id);
      persistRetryQueue();
      renderStage();
    }

    async function retryPending(id) {
      const item = state.retryQueue.find((r) => r.id === id);
      if (!item) return;
      item.status = "sending";
      persistRetryQueue();
      renderStage();
      try {
        const sessionID = item.sessionID || state.selectedSessionId;
        if (sessionID) {
          const localSessionId = await ensureLocalSessionID(sessionID);
          item.sessionID = localSessionId;
          await api(`/api/sessions/${localSessionId}/messages`, { method: "POST", json: { prompt: item.prompt } });
        } else {
          const detail = await api("/api/sessions", {
            method: "POST",
            json: { prompt: item.prompt, workspaceID: item.workspaceID || state.selectedWorkspaceId, openWindow: false },
          });
          state.selectedSessionId = detail.session.id;
          state.sessionDetail = detail;
        }
        dropPending(id);
        await refreshAll();
        toast("Enviado", "success", 1200);
      } catch (err) {
        markPendingFailed(id, err?.message || "Error");
        toast("Sigue fallando", "error");
      }
    }

    function maybeDrainRetryQueue() {
      // On boot, leave failed items marked; user can retry manually.
    }

    function pruneRetryQueueAgainstServer(detail) {
      // Very simple heuristic: if the last user entry text matches a pending, drop it
      if (!detail?.activity?.length) return;
      const texts = detail.activity
        .filter((e) => e.kind === "user")
        .map((e) => (e.detail || e.title || "").trim());
      const before = state.retryQueue.length;
      state.retryQueue = state.retryQueue.filter((r) => {
        if (r.sessionID !== detail.session.id) return true;
        if (r.status !== "sending") return true;
        return !texts.includes(r.prompt.trim());
      });
      if (state.retryQueue.length !== before) persistRetryQueue();
    }

    async function handleSlashAction(action) {
      if (action === "stop") return stopSession(state.selectedSessionId);
      if (action === "new") return startNewSession();
      if (action === "focus") return focusSession(state.selectedSessionId);
      if (action === "clear") { els.composer.value = ""; autoGrow(); saveDraft(state.selectedSessionId, ""); return; }
      if (action === "subagents") {
        state.subagentsMode = true;
        renderRuntimeControls();
        toast("Modo subagentes armado para el próximo envío", "success", 1500);
        return;
      }
    }

    function startNewSession() {
      state.selectedSessionId = null;
      localStorage.removeItem(STORAGE.session);
      state.sessionDetail = null;
      state.subagentsMode = false;
      clearAttachments();
      renderSessions();
      renderStage();
      updateTopbar();
      renderCarModePanel();
      loadComposerDraft();
      els.composer.focus();
      if (state.drawerOpen && matchMedia("(max-width: 900px)").matches) openDrawer(false);
    }

    async function focusSession(id) {
      if (!id) return;
      try {
        const localSessionId = await ensureLocalSessionID(id);
        await api(`/api/sessions/${localSessionId}/focus`, { method: "POST" });
        toast("Abriendo en el Mac…", "info", 1200);
      }
      catch (err) { toast("No se pudo enfocar", "error"); }
    }

    async function stopSession(id) {
      if (!id) return;
      try {
        const localSessionId = await ensureLocalSessionID(id);
        await api(`/api/sessions/${localSessionId}/stop`, { method: "POST" });
        vibrate(10);
        toast("Detenido", "success", 1100);
        refreshAll();
      } catch (err) { toast("No se pudo detener", "error"); }
    }

    async function deleteSessionById(id) {
      if (!id) return;
      if (!confirm("¿Borrar esta sesión? El historial local se pierde.")) return;
      try {
        const localSessionId = await ensureLocalSessionID(id);
        await api(`/api/sessions/${localSessionId}`, { method: "DELETE" });
        state.pinned.delete(id); saveJSON(STORAGE.pinnedSessions, [...state.pinned]);
        state.archived.delete(id); saveJSON(STORAGE.archivedSessions, [...state.archived]);
        state.pinned.delete(localSessionId); saveJSON(STORAGE.pinnedSessions, [...state.pinned]);
        state.archived.delete(localSessionId); saveJSON(STORAGE.archivedSessions, [...state.archived]);
        if (state.selectedSessionId === id || state.selectedSessionId === localSessionId) state.selectedSessionId = null;
        await refreshAll();
        toast("Sesión borrada", "success", 1400);
      } catch (err) {
        toast(err.message || "No se pudo borrar", "error");
      }
    }

    async function renameSessionById(id, newTitle) {
      if (!id || !newTitle?.trim()) return;
      try {
        const localSessionId = await ensureLocalSessionID(id);
        await api(`/api/sessions/${localSessionId}`, { method: "PATCH", json: { title: newTitle.trim() } });
        await refreshAll();
        toast("Renombrada", "success", 1000);
      } catch (err) { toast("No se pudo renombrar", "error"); }
    }

    function togglePinSession(id) {
      if (state.pinned.has(id)) state.pinned.delete(id);
      else state.pinned.add(id);
      saveJSON(STORAGE.pinnedSessions, [...state.pinned]);
      renderSessions();
    }

    function toggleArchiveSession(id) {
      if (state.archived.has(id)) state.archived.delete(id);
      else state.archived.add(id);
      saveJSON(STORAGE.archivedSessions, [...state.archived]);
      renderSessions();
    }

    function startRenameInline(id) {
      if (!id) return;
      const cur = els.sessionTitle.textContent;
      els.sessionTitle.contentEditable = "plaintext-only";
      els.sessionTitle.focus();
      const range = document.createRange();
      range.selectNodeContents(els.sessionTitle);
      const sel = window.getSelection();
      sel.removeAllRanges(); sel.addRange(range);
      const finish = async (commit) => {
        els.sessionTitle.removeEventListener("blur", onBlur);
        els.sessionTitle.removeEventListener("keydown", onKey);
        els.sessionTitle.contentEditable = "false";
        const val = els.sessionTitle.textContent.trim();
        if (commit && val && val !== cur) await renameSessionById(id, val);
        else els.sessionTitle.textContent = cur;
      };
      const onBlur = () => finish(true);
      const onKey = (e) => {
        if (e.key === "Enter") { e.preventDefault(); finish(true); }
        if (e.key === "Escape") { e.preventDefault(); finish(false); }
      };
      els.sessionTitle.addEventListener("blur", onBlur);
      els.sessionTitle.addEventListener("keydown", onKey);
    }

    // ===== Session kebab menu =====
    function openSessionMenu(id, anchor) {
      if (!id) return;
      closeAnyOpenMenus();
      const rect = anchor.getBoundingClientRect();
      const menu = document.createElement("div");
      menu.className = "menu-popover";
      menu.setAttribute("data-menu-root", "true");
      const isPinned = state.pinned.has(id);
      const isArchived = state.archived.has(id);
      menu.innerHTML = `
        <button class="menu-item" data-act="select">Abrir</button>
        <button class="menu-item" data-act="rename">Renombrar</button>
        <button class="menu-item" data-act="pin">${isPinned ? "Desfijar" : "Fijar"}</button>
        <button class="menu-item" data-act="archive">${isArchived ? "Desarchivar" : "Archivar"}</button>
        <button class="menu-item" data-act="focus">Abrir en el Mac</button>
        <button class="menu-item" data-kind="danger" data-act="delete">Borrar</button>
      `;
      document.body.appendChild(menu);
      const menuRect = menu.getBoundingClientRect();
      const left = Math.min(rect.right - menuRect.width, window.innerWidth - menuRect.width - 8);
      const top = Math.min(rect.bottom + 6, window.innerHeight - menuRect.height - 8);
      menu.style.left = `${Math.max(8, left)}px`;
      menu.style.top = `${Math.max(8, top)}px`;
      menu.addEventListener("click", async (e) => {
        const act = e.target.closest("[data-act]")?.dataset.act;
        if (!act) return;
        menu.remove();
        if (act === "select") await selectSession(id);
        else if (act === "rename") {
          if (!sessionMatchesID(findSession(id), state.selectedSessionId)) await selectSession(id);
          setTimeout(() => startRenameInline(state.selectedSessionId), 60);
        }
        else if (act === "pin") togglePinSession(id);
        else if (act === "archive") toggleArchiveSession(id);
        else if (act === "focus") focusSession(id);
        else if (act === "delete") deleteSessionById(id);
      });
    }

    function closeAnyOpenMenus(e) {
      const keep = e?.target?.closest("[data-menu-root]") || e?.target?.closest(".session-item-kebab") || e?.target?.closest("#session-menu-button");
      if (keep) return;
      document.querySelectorAll(".menu-popover").forEach((m) => m.remove());
    }

    // ===== Slash commands + @-mentions =====
    function maybeShowSuggestions() {
      const value = els.composer.value;
      const cursor = els.composer.selectionStart;
      const upto = value.slice(0, cursor);
      // Slash at start
      const slashMatch = upto.match(/(^|\n)\/(\w*)$/);
      if (slashMatch) {
        showSlashSuggestions(slashMatch[2]);
        return;
      }
      // @file
      const atMatch = upto.match(/(?:^|\s)@([\w\-./]*)$/);
      if (atMatch) {
        showFileSuggestions(atMatch[1]);
        return;
      }
      hideSuggestions();
    }

    function showSlashSuggestions(query) {
      const q = (query || "").toLowerCase();
      const items = SLASH_COMMANDS.filter((c) => c.slug.startsWith(q) || c.label.includes(q))
        .slice(0, 8)
        .map((c) => ({
          id: c.slug,
          icon: "/",
          title: c.label,
          subtitle: c.subtitle,
          onPick: () => insertSlashCompletion(c),
        }));
      setSuggestions("Comandos", items);
    }

    async function showFileSuggestions(query) {
      if (!state.selectedWorkspaceId) { hideSuggestions(); return; }
      setSuggestions("Archivos", [{ id: "loading", icon: "…", title: "Buscando…", subtitle: "", onPick: () => {} }]);
      try {
        const res = await api(`/api/workspaces/${state.selectedWorkspaceId}/files?q=${encodeURIComponent(query)}&limit=10`);
        const items = (res.results || []).map((r) => ({
          id: r.path,
          icon: iconForExt(r.kind),
          title: r.displayName,
          subtitle: r.relativePath,
          onPick: () => insertMentionCompletion(r),
        }));
        if (!items.length) items.push({ id: "none", icon: "∅", title: "Sin resultados", subtitle: "Prueba otro nombre", onPick: () => {} });
        setSuggestions(`Archivos · ${state.workspaces.find((w) => w.id === state.selectedWorkspaceId)?.name || ""}`, items);
      } catch { hideSuggestions(); }
    }

    function iconForExt(ext) {
      return (ext || "").slice(0, 2).toUpperCase() || "¶";
    }

    function setSuggestions(header, items) {
      state.suggestionItems = items;
      state.suggestionActiveIndex = items.length ? 0 : -1;
      els.suggestionHeader.textContent = header;
      els.suggestionList.innerHTML = "";
      items.forEach((it, i) => {
        const el = document.createElement("button");
        el.type = "button";
        el.className = "suggestion-item";
        if (i === state.suggestionActiveIndex) el.dataset.active = "true";
        el.innerHTML = `
          <div class="suggestion-icon">${escapeHTML(it.icon || "·")}</div>
          <div class="suggestion-main">
            <div class="suggestion-title">${escapeHTML(it.title)}</div>
            <div class="suggestion-subtitle">${escapeHTML(it.subtitle || "")}</div>
          </div>
          <span class="suggestion-shortcut">${i === 0 ? "↵" : ""}</span>
        `;
        el.addEventListener("mousedown", (e) => { e.preventDefault(); it.onPick(); hideSuggestions(); });
        els.suggestionList.appendChild(el);
      });
      els.suggestionPopup.hidden = !items.length;
    }

    function moveSuggestion(delta) {
      if (!state.suggestionItems.length) return;
      state.suggestionActiveIndex = (state.suggestionActiveIndex + delta + state.suggestionItems.length) % state.suggestionItems.length;
      els.suggestionList.querySelectorAll(".suggestion-item").forEach((el, i) => {
        if (i === state.suggestionActiveIndex) el.dataset.active = "true"; else delete el.dataset.active;
        if (i === state.suggestionActiveIndex) el.scrollIntoView({ block: "nearest" });
      });
    }

    function acceptSuggestion() {
      const item = state.suggestionItems[state.suggestionActiveIndex];
      if (item) { item.onPick(); hideSuggestions(); }
    }

    function hideSuggestions() {
      els.suggestionPopup.hidden = true;
      state.suggestionItems = [];
      state.suggestionActiveIndex = -1;
    }

    function insertSlashCompletion(cmd) {
      if (cmd.action === "subagents") {
        state.subagentsMode = true;
        const ta = els.composer;
        const value = ta.value;
        const cursor = ta.selectionStart;
        const upto = value.slice(0, cursor);
        const rest = value.slice(cursor);
        const replaced = upto.replace(/(^|\n)\/\w*$/, "$1");
        ta.value = replaced + rest;
        const caret = replaced.length;
        ta.setSelectionRange(caret, caret);
        autoGrow();
        ta.focus();
        renderRuntimeControls();
        toast("Modo subagentes armado para el próximo envío", "success", 1500);
        return;
      }
      const ta = els.composer;
      const value = ta.value;
      const cursor = ta.selectionStart;
      const upto = value.slice(0, cursor);
      const rest = value.slice(cursor);
      const replaced = upto.replace(/(^|\n)\/\w*$/, (m, pre) => pre + (cmd.template ?? cmd.label + " "));
      ta.value = replaced + rest;
      const caret = replaced.length;
      ta.setSelectionRange(caret, caret);
      autoGrow();
      ta.focus();
    }

    function insertMentionCompletion(file) {
      const ta = els.composer;
      const value = ta.value;
      const cursor = ta.selectionStart;
      const upto = value.slice(0, cursor);
      const rest = value.slice(cursor);
      const replaced = upto.replace(/(?:^|\s)@[\w\-./]*$/, (m) => {
        const leading = m.startsWith(" ") || m.startsWith("\n") ? m[0] : "";
        return leading + "@" + file.relativePath + " ";
      });
      ta.value = replaced + rest;
      const caret = replaced.length;
      ta.setSelectionRange(caret, caret);
      autoGrow();
      ta.focus();
    }

    // ===== Command palette =====
    function togglePalette() {
      if (els.commandPalette.hidden) openPalette();
      else closePalette();
    }

    function openPalette() {
      state.paletteItems = buildPaletteItems();
      els.paletteInput.value = "";
      filterPalette();
      els.commandPalette.hidden = false;
      setTimeout(() => els.paletteInput.focus(), 30);
    }

    function closePalette() {
      els.commandPalette.hidden = true;
    }

    function buildPaletteItems() {
      const items = [];
      items.push({ group: "Acciones", icon: "+", title: "Nueva sesión", subtitle: "⌘⇧N", run: startNewSession });
      items.push({ group: "Acciones", icon: "⎋", title: "Detener sesión", subtitle: "Detiene el proceso actual", run: () => stopSession(state.selectedSessionId) });
      items.push({ group: "Acciones", icon: "↗", title: "Abrir en el Mac", subtitle: "Enfoca la ventana nativa", run: () => focusSession(state.selectedSessionId) });
      items.push({ group: "Acciones", icon: "✎", title: "Renombrar sesión", subtitle: "Enter para confirmar", run: () => startRenameInline(state.selectedSessionId) });
      items.push({ group: "Acciones", icon: "🗑", title: "Borrar sesión actual", subtitle: "Pide confirmación", run: () => deleteSessionById(state.selectedSessionId) });
      items.push({ group: "Vista", icon: "◐", title: "Tema claro / oscuro", subtitle: "Alterna tema", run: toggleTheme });
      items.push({ group: "Vista", icon: "↻", title: "Refrescar todo", subtitle: "Recarga workspaces y sesiones", run: refreshAll });
      for (const w of state.workspaces) {
        items.push({
          group: "Workspaces",
          icon: (w.name || "?").slice(0, 2).toUpperCase(),
          title: `Workspace: ${w.name}`,
          subtitle: w.path,
          run: () => {
            if (state.selectedWorkspaceId === w.id) return;
            state.selectedWorkspaceId = w.id;
            state.selectedSessionId = null;
            state.sessionDetail = null;
            localStorage.setItem(STORAGE.workspace, w.id);
            localStorage.removeItem(STORAGE.session);
            renderWorkspaceChips();
            refreshAll();
            toast(`Workspace ${w.name}`, "info", 900);
          },
        });
      }
      for (const s of filterSessionsForSelectedWorkspace(state.sessions)) {
        items.push({
          group: "Sesiones",
          icon: "§",
          title: s.title || "Sin título",
          subtitle: `${s.workspaceName || ""} · ${timeShort(new Date(s.updatedAt))}`,
          run: () => selectSession(s.id),
        });
      }
      for (const c of SLASH_COMMANDS.filter((c) => c.template)) {
        items.push({
          group: "Plantillas",
          icon: "/",
          title: c.label,
          subtitle: c.subtitle,
          run: () => { els.composer.value = c.template; autoGrow(); els.composer.focus(); },
        });
      }
      return items;
    }

    function filterPalette() {
      const q = els.paletteInput.value.trim().toLowerCase();
      let items = state.paletteItems;
      if (q) {
        items = items
          .map((it) => ({ it, score: paletteScore(q, it) }))
          .filter((x) => x.score > 0)
          .sort((a, b) => b.score - a.score)
          .map((x) => x.it);
      }
      state.paletteFiltered = items.slice(0, 40);
      state.paletteActiveIndex = 0;
      renderPaletteResults();
    }

    function paletteScore(q, it) {
      const title = (it.title || "").toLowerCase();
      const sub = (it.subtitle || "").toLowerCase();
      if (title === q) return 100;
      if (title.startsWith(q)) return 80;
      if (title.includes(q)) return 50;
      if (sub.includes(q)) return 20;
      // subsequence
      let qi = 0;
      for (const ch of title) { if (qi < q.length && ch === q[qi]) qi++; }
      return qi === q.length ? 5 : 0;
    }

    function renderPaletteResults() {
      els.paletteResults.innerHTML = "";
      if (!state.paletteFiltered.length) {
        els.paletteResults.innerHTML = `<div class="palette-group-label" style="padding: 18px;">Nada aquí</div>`;
        return;
      }
      let group = null;
      state.paletteFiltered.forEach((it, i) => {
        if (it.group !== group) {
          group = it.group;
          const label = document.createElement("div");
          label.className = "palette-group-label";
          label.textContent = group;
          els.paletteResults.appendChild(label);
        }
        const el = document.createElement("button");
        el.type = "button";
        el.className = "palette-item";
        if (i === state.paletteActiveIndex) el.dataset.active = "true";
        el.innerHTML = `
          <div class="palette-item-icon">${escapeHTML(it.icon || "·")}</div>
          <div class="palette-item-main">
            <div class="palette-item-title">${escapeHTML(it.title)}</div>
            <div class="palette-item-sub">${escapeHTML(it.subtitle || "")}</div>
          </div>
          <span class="suggestion-shortcut">${i === state.paletteActiveIndex ? "↵" : ""}</span>
        `;
        el.addEventListener("click", () => runPaletteItem(it));
        els.paletteResults.appendChild(el);
      });
    }

    function handlePaletteKey(e) {
      if (e.key === "ArrowDown") { e.preventDefault(); movePalette(1); }
      else if (e.key === "ArrowUp") { e.preventDefault(); movePalette(-1); }
      else if (e.key === "Enter") { e.preventDefault(); executePalette(); }
      else if (e.key === "Escape") { e.preventDefault(); closePalette(); }
    }

    function movePalette(delta) {
      if (!state.paletteFiltered.length) return;
      state.paletteActiveIndex = (state.paletteActiveIndex + delta + state.paletteFiltered.length) % state.paletteFiltered.length;
      renderPaletteResults();
      els.paletteResults.querySelector('[data-active="true"]')?.scrollIntoView({ block: "nearest" });
    }

    function executePalette() {
      const it = state.paletteFiltered[state.paletteActiveIndex];
      if (!it) return;
      runPaletteItem(it);
    }

    function runPaletteItem(item) {
      closePalette();
      Promise.resolve(item.run?.()).catch((err) => {
        console.error("[miwhisper] palette action failed", err);
        renderConnection("error", "No se pudo ejecutar la acción");
      });
    }

    // ===== Voice recording =====
    function handleVoiceTouchStart(e) {
      e.preventDefault();
      state.recordingTouchStartX = e.touches[0].clientX;
      state.recordingCancel = false;
      startRecording();
    }

    function handleVoiceTouchMove(e) {
      if (!state.recording) return;
      const dx = e.touches[0].clientX - state.recordingTouchStartX;
      const shouldCancel = dx < -80;
      if (shouldCancel !== state.recordingCancel) {
        state.recordingCancel = shouldCancel;
        els.voiceOverlay.dataset.cancel = shouldCancel ? "true" : "false";
        els.voiceHint.textContent = shouldCancel ? "Suelta aquí para cancelar" : "Suelta para enviar · Desliza izquierda para cancelar";
      }
    }

    function handleVoiceTouchEnd() {
      if (!state.recording) return;
      stopRecording({ cancel: state.recordingCancel });
    }

    async function toggleRecording() {
      if (state.voiceProcessing) return;
      if (state.recording) { stopRecording({ cancel: false }); return; }
      startRecording();
    }

    async function startRecording() {
      if (state.recording) return;
      if (state.voiceProcessing) return;
      if (!navigator.mediaDevices?.getUserMedia) {
        toast("Este navegador no expone micrófono. Abre la PWA por HTTPS de Tailscale, no por http://IP:6009.", "error", 6200);
        return;
      }
      if (!window.isSecureContext) {
        toast("iOS solo permite micrófono en HTTPS. Usa la URL HTTPS de Tailscale Serve para esta PWA.", "error", 7000);
        return;
      }
      try {
        state.mediaStream = await navigator.mediaDevices.getUserMedia({ audio: true });
      } catch (err) {
        toast(microphoneErrorMessage(err), "error", 7000);
        return;
      }
      state.recordedChunks = [];
      state.pcmChunks = [];

      const mimeType = pickSupportedMimeType();
      const shouldUsePCM = !window.MediaRecorder || !mimeType || mimeType.toLowerCase().includes("webm");
      state.recordingMode = shouldUsePCM ? "pcm" : "media";

      if (state.recordingMode === "media") {
        const opts = mimeType ? { mimeType } : undefined;
        try { state.mediaRecorder = new MediaRecorder(state.mediaStream, opts); }
        catch {
          state.recordingMode = "pcm";
          state.mediaRecorder = null;
        }
      }

      if (state.recordingMode === "media" && state.mediaRecorder) {
        state.recordedMimeType = state.mediaRecorder.mimeType || mimeType || "audio/mp4";
        state.recordedExtension = inferExtension(state.recordedMimeType);
        state.mediaRecorder.addEventListener("dataavailable", (evt) => {
          if (evt.data?.size) state.recordedChunks.push(evt.data);
        });
        state.mediaRecorder.addEventListener("stop", onMediaRecorderStop);
        state.mediaRecorder.start();
        setupAudioWaveform({ capturePCM: false });
      } else {
        state.recordedMimeType = "audio/wav";
        state.recordedExtension = "wav";
        if (!setupAudioWaveform({ capturePCM: true })) {
          state.mediaStream?.getTracks().forEach((t) => t.stop());
          state.mediaStream = null;
          state.pcmChunks = [];
          toast("No puedo preparar la grabación WAV en este navegador.", "error");
          return;
        }
      }

      state.recording = true;
      state.recordStartedAt = performance.now();
      els.voiceButton.dataset.recording = "true";
      els.micTimer.hidden = false;
      els.voiceOverlay.hidden = false;
      els.voiceOverlay.dataset.cancel = "false";
      renderCarModePanel();
      syncNativeCarCommandListening(state.sessionDetail, { reason: "recording-start" });
      updateVoiceTimer();
      state.recordTimerHandle = setInterval(updateVoiceTimer, 200);
      vibrate(18);
    }

    function microphoneErrorMessage(err) {
      const name = err?.name || "";
      if (name === "NotAllowedError" || name === "SecurityError") {
        return "Permiso de micrófono denegado. En iOS revisa Ajustes > Safari > Micrófono y abre la PWA por HTTPS de Tailscale.";
      }
      if (name === "NotFoundError" || name === "DevicesNotFoundError") {
        return "No encuentro micrófono disponible en este dispositivo.";
      }
      if (name === "NotReadableError" || name === "AbortError") {
        return "El micrófono está ocupado o iOS no pudo iniciarlo. Cierra otras apps de audio y vuelve a intentar.";
      }
      return `No puedo iniciar el micrófono${name ? ` (${name})` : ""}. Usa HTTPS de Tailscale y revisa permisos de Safari.`;
    }

    function resetRecordingUI() {
      state.recording = false;
      els.voiceButton.dataset.recording = "false";
      els.micTimer.hidden = true;
      els.voiceOverlay.hidden = true;
      els.micTimer.textContent = "0:00";
      els.voiceTimer.textContent = "0:00";
      renderCarModePanel();
      syncNativeCarCommandListening(state.sessionDetail, { reason: "recording-reset" });
    }

    async function uploadVoiceBlob(blob, extension, mimeType) {
      setVoiceProcessing(true, "Subiendo audio...");
      try {
        await waitForPaint();
        state.voiceProcessingTimer = setTimeout(() => {
          setVoiceProcessing(true, "Transcribiendo audio...");
        }, 900);
        const transcript = await api(`/api/voice/transcribe?ext=${encodeURIComponent(extension)}`, {
          method: "POST",
          body: blob,
          headers: { "Content-Type": mimeType },
        });
        const text = (transcript.transcript || "").trim();
        if (!text) { toast("No se detectó audio", "warn"); return; }
        const composer = els.composer;
        const cur = composer.value;
        composer.value = cur ? cur + (cur.endsWith("\n") ? "" : " ") + text : text;
        autoGrow();
        saveDraft(state.selectedSessionId, composer.value);
        vibrate([10, 40, 10]);
        if (state.runtimePrefs.carMode) {
          await waitForPaint();
          await sendComposer();
        } else {
          composer.focus();
        }
      } catch (err) {
        toast(err.message || "Error al transcribir", "error");
      } finally {
        setVoiceProcessing(false);
      }
    }

    function waitForPaint() {
      return new Promise((resolve) => {
        if (typeof requestAnimationFrame !== "function") {
          setTimeout(resolve, 0);
          return;
        }
        requestAnimationFrame(() => requestAnimationFrame(resolve));
      });
    }

    function setVoiceProcessing(active, message = "Subiendo audio...") {
      state.voiceProcessing = active;
      if (state.voiceProcessingTimer) {
        clearTimeout(state.voiceProcessingTimer);
        state.voiceProcessingTimer = null;
      }
      els.voiceProcessing.hidden = !active;
      els.voiceButton.disabled = active;
      els.voiceButton.dataset.processing = active ? "true" : "false";
      els.composerShell.setAttribute("aria-busy", active ? "true" : "false");
      if (active) {
        els.voiceProcessingText.textContent = message;
      }
      renderCarModePanel();
      syncNativeCarCommandListening(state.sessionDetail, { reason: "voice-processing" });
    }

    async function onMediaRecorderStop() {
      const stream = state.mediaStream;
      cleanupRecording();
      resetRecordingUI();
      stream?.getTracks().forEach((t) => t.stop());
      const chunks = state.recordedChunks;
      state.recordedChunks = [];
      if (state.recordingCancel) {
        state.recordingCancel = false;
        toast("Grabación cancelada", "info", 900);
        return;
      }
      if (!chunks.length) return;
      setVoiceProcessing(true, "Preparando audio...");
      await waitForPaint();
      const blob = new Blob(chunks, { type: state.recordedMimeType });
      await uploadVoiceBlob(blob, state.recordedExtension, state.recordedMimeType);
    }

    async function finishPCMRecording() {
      const stream = state.mediaStream;
      const chunks = state.pcmChunks;
      const sampleRate = state.pcmInputSampleRate || state.audioContext?.sampleRate || 44100;
      cleanupRecording();
      resetRecordingUI();
      stream?.getTracks().forEach((t) => t.stop());
      state.pcmChunks = [];
      if (state.recordingCancel) {
        state.recordingCancel = false;
        toast("Grabación cancelada", "info", 900);
        return;
      }
      if (!chunks.length) return;
      setVoiceProcessing(true, "Preparando audio...");
      await waitForPaint();
      const blob = encodeWav(chunks, sampleRate, 16000);
      await uploadVoiceBlob(blob, "wav", "audio/wav");
    }

    function stopRecording({ cancel }) {
      if (!state.recording) return;
      state.recordingCancel = !!cancel;
      if (state.recordTimerHandle) { clearInterval(state.recordTimerHandle); state.recordTimerHandle = null; }
      if (state.recordingMode === "pcm") {
        finishPCMRecording();
        return;
      }
      if (!state.mediaRecorder) return;
      try { state.mediaRecorder.stop(); } catch {}
    }

    function cleanupRecording() {
      if (state.audioRaf) cancelAnimationFrame(state.audioRaf);
      state.audioRaf = null;
      if (state.audioProcessor) {
        try { state.audioProcessor.disconnect(); } catch {}
        state.audioProcessor.onaudioprocess = null;
      }
      if (state.audioSource) {
        try { state.audioSource.disconnect(); } catch {}
      }
      if (state.audioAnalyser) {
        try { state.audioAnalyser.disconnect(); } catch {}
      }
      if (state.audioContext) {
        try { state.audioContext.close(); } catch {}
      }
      state.audioContext = null;
      state.audioAnalyser = null;
      state.audioSource = null;
      state.audioProcessor = null;
      state.pcmInputSampleRate = 0;
    }

    function setupAudioWaveform({ capturePCM = false } = {}) {
      try {
        state.audioContext = new (window.AudioContext || window.webkitAudioContext)();
        state.audioSource = state.audioContext.createMediaStreamSource(state.mediaStream);
        state.audioAnalyser = state.audioContext.createAnalyser();
        state.audioAnalyser.fftSize = 1024;
        state.audioSource.connect(state.audioAnalyser);
        if (capturePCM) {
          state.pcmInputSampleRate = state.audioContext.sampleRate || 44100;
          state.audioProcessor = state.audioContext.createScriptProcessor(4096, 1, 1);
          state.audioProcessor.onaudioprocess = (evt) => {
            if (!state.recording || state.recordingMode !== "pcm") return;
            const input = evt.inputBuffer.getChannelData(0);
            state.pcmChunks.push(new Float32Array(input));
          };
          state.audioSource.connect(state.audioProcessor);
          state.audioProcessor.connect(state.audioContext.destination);
        }
        drawWaveform();
        return true;
      } catch (err) {
        console.warn("[miwhisper] waveform not available", err);
        return false;
      }
    }

    function drawWaveform() {
      const canvas = els.voiceCanvas;
      if (!canvas || !state.audioAnalyser) return;
      const ctx = canvas.getContext("2d");
      const analyser = state.audioAnalyser;
      const bufferLength = analyser.fftSize;
      const dataArray = new Uint8Array(bufferLength);
      const cssWidth = canvas.clientWidth || canvas.width;
      const cssHeight = canvas.clientHeight || canvas.height;
      const dpr = window.devicePixelRatio || 1;
      canvas.width = cssWidth * dpr;
      canvas.height = cssHeight * dpr;
      ctx.scale(dpr, dpr);

      const loop = () => {
        if (!state.audioAnalyser) return;
        analyser.getByteTimeDomainData(dataArray);
        ctx.clearRect(0, 0, cssWidth, cssHeight);
        ctx.lineWidth = 2;
        ctx.strokeStyle = state.recordingCancel ? "#d97706" : "#dc2626";
        ctx.beginPath();
        const sliceWidth = cssWidth / bufferLength;
        let x = 0;
        for (let i = 0; i < bufferLength; i++) {
          const v = dataArray[i] / 128.0;
          const y = (v * cssHeight) / 2;
          if (i === 0) ctx.moveTo(x, y);
          else ctx.lineTo(x, y);
          x += sliceWidth;
        }
        ctx.lineTo(cssWidth, cssHeight / 2);
        ctx.stroke();
        state.audioRaf = requestAnimationFrame(loop);
      };
      loop();
    }

    function updateVoiceTimer() {
      if (!state.recordStartedAt) return;
      const elapsed = Math.floor((performance.now() - state.recordStartedAt) / 1000);
      const m = Math.floor(elapsed / 60);
      const s = elapsed % 60;
      const label = `${m}:${s.toString().padStart(2, "0")}`;
      els.micTimer.textContent = label;
      els.voiceTimer.textContent = label;
    }

    function pickSupportedMimeType() {
      const appleRecorder = /iPhone|iPad|iPod|Macintosh/.test(navigator.userAgent || navigator.platform || "");
      const candidates = appleRecorder
        ? ["audio/mp4;codecs=mp4a.40.2", "audio/mp4", "audio/aac", "audio/webm;codecs=opus", "audio/webm"]
        : ["audio/webm;codecs=opus", "audio/webm", "audio/mp4;codecs=mp4a.40.2", "audio/mp4", "audio/aac"];
      if (!window.MediaRecorder?.isTypeSupported) return "";
      for (const c of candidates) {
        if (MediaRecorder.isTypeSupported(c)) return c;
      }
      return "";
    }

    function inferExtension(mimeType) {
      const m = (mimeType || "").toLowerCase();
      if (m.includes("webm")) return "webm";
      if (m.includes("mp4") || m.includes("aac")) return "m4a";
      if (m.includes("wav")) return "wav";
      return "m4a";
    }

    function encodeWav(chunks, inputSampleRate, outputSampleRate = 16000) {
      const samples = downsamplePCM(flattenPCM(chunks), inputSampleRate, outputSampleRate);
      const buffer = new ArrayBuffer(44 + samples.length * 2);
      const view = new DataView(buffer);
      writeASCII(view, 0, "RIFF");
      view.setUint32(4, 36 + samples.length * 2, true);
      writeASCII(view, 8, "WAVE");
      writeASCII(view, 12, "fmt ");
      view.setUint32(16, 16, true);
      view.setUint16(20, 1, true);
      view.setUint16(22, 1, true);
      view.setUint32(24, outputSampleRate, true);
      view.setUint32(28, outputSampleRate * 2, true);
      view.setUint16(32, 2, true);
      view.setUint16(34, 16, true);
      writeASCII(view, 36, "data");
      view.setUint32(40, samples.length * 2, true);
      let offset = 44;
      for (let i = 0; i < samples.length; i++, offset += 2) {
        const s = Math.max(-1, Math.min(1, samples[i]));
        view.setInt16(offset, s < 0 ? s * 0x8000 : s * 0x7fff, true);
      }
      return new Blob([view], { type: "audio/wav" });
    }

    function flattenPCM(chunks) {
      const length = chunks.reduce((sum, chunk) => sum + chunk.length, 0);
      const out = new Float32Array(length);
      let offset = 0;
      for (const chunk of chunks) {
        out.set(chunk, offset);
        offset += chunk.length;
      }
      return out;
    }

    function downsamplePCM(samples, inputRate, outputRate) {
      if (!inputRate || inputRate === outputRate) return samples;
      const ratio = inputRate / outputRate;
      const length = Math.max(1, Math.round(samples.length / ratio));
      const out = new Float32Array(length);
      for (let i = 0; i < length; i++) {
        const start = Math.floor(i * ratio);
        const end = Math.min(samples.length, Math.floor((i + 1) * ratio));
        let sum = 0;
        let count = 0;
        for (let j = start; j < end; j++) {
          sum += samples[j];
          count++;
        }
        out[i] = count ? sum / count : 0;
      }
      return out;
    }

    function writeASCII(view, offset, value) {
      for (let i = 0; i < value.length; i++) {
        view.setUint8(offset + i, value.charCodeAt(i));
      }
    }

    // ===== Markdown rendering (compact, safe) =====
    function renderMarkdown(text) {
      const out = [];
      const lines = text.split("\n");
      let i = 0;
      while (i < lines.length) {
        const line = lines[i];
        const trimmed = line.trim();
        if (!trimmed) { i++; continue; }
        // fenced code
        const fence = line.match(/^```(\w*)\s*$/);
        if (fence) {
          const lang = fence[1] || "plain";
          const buf = [];
          i++;
          while (i < lines.length && !/^```/.test(lines[i])) { buf.push(lines[i]); i++; }
          if (i < lines.length) i++;
          out.push(renderCodeBlockWrapper(buf.join("\n"), lang));
          continue;
        }
        if (/^(#{1,6})\s+/.test(trimmed)) {
          const match = trimmed.match(/^(#{1,6})\s+(.*)$/);
          const level = match[1].length;
          out.push(`<h${level}>${renderInline(match[2])}</h${level}>`);
          i++; continue;
        }
        if (/^---+$/.test(trimmed) || /^\*\*\*+$/.test(trimmed)) { out.push("<hr>"); i++; continue; }
        if (/^> /.test(line)) {
          const buf = [];
          while (i < lines.length && /^> /.test(lines[i])) { buf.push(lines[i].replace(/^> ?/, "")); i++; }
          out.push(`<blockquote>${renderMarkdown(buf.join("\n"))}</blockquote>`);
          continue;
        }
        if (/^\s*[-*+] /.test(line)) {
          const buf = [];
          while (i < lines.length && /^\s*[-*+] /.test(lines[i])) { buf.push(lines[i].replace(/^\s*[-*+] /, "")); i++; }
          out.push(`<ul>${buf.map((b) => `<li>${renderInline(b)}</li>`).join("")}</ul>`);
          continue;
        }
        if (/^\s*\d+\. /.test(line)) {
          const buf = [];
          while (i < lines.length && /^\s*\d+\. /.test(lines[i])) { buf.push(lines[i].replace(/^\s*\d+\. /, "")); i++; }
          out.push(`<ol>${buf.map((b) => `<li>${renderInline(b)}</li>`).join("")}</ol>`);
          continue;
        }
        if (/\|/.test(line) && i + 1 < lines.length && isMarkdownTableSeparator(lines[i + 1])) {
          const header = splitMarkdownTableRow(line);
          const alignments = tableAlignments(splitMarkdownTableRow(lines[i + 1]));
          i += 2;
          const rows = [];
          while (i < lines.length && /\|/.test(lines[i])) {
            rows.push(splitMarkdownTableRow(lines[i]));
            i++;
          }
          out.push(renderMarkdownTable(header, alignments, rows));
          continue;
        }
        const buf = [];
        while (i < lines.length && lines[i].trim()) { buf.push(lines[i]); i++; }
        out.push(`<p>${renderInline(buf.join("\n")).replace(/\n/g, "<br>")}</p>`);
      }
      return out.join("\n");
    }

    function renderMarkdownTable(header, alignments, rows) {
      const columnCount = Math.max(header.length, ...rows.map((r) => r.length), 0);
      if (!columnCount) return "";
      const normalize = (cells) => {
        const next = cells.slice(0, columnCount);
        while (next.length < columnCount) next.push("");
        return next;
      };
      const alignAttr = (idx) => alignments[idx] ? ` style="text-align: ${alignments[idx]}"` : "";
      const head = normalize(header).map((h, idx) => `<th${alignAttr(idx)}>${renderInline(h)}</th>`).join("");
      const body = rows.map((row) => {
        const cells = normalize(row).map((c, idx) => `<td${alignAttr(idx)}>${renderInline(c)}</td>`).join("");
        return `<tr>${cells}</tr>`;
      }).join("");
      return `<table><thead><tr>${head}</tr></thead><tbody>${body}</tbody></table>`;
    }

    function tableAlignments(cells) {
      return cells.map((cell) => {
        const trimmed = cell.trim();
        const left = trimmed.startsWith(":");
        const right = trimmed.endsWith(":");
        if (left && right) return "center";
        if (right) return "right";
        if (left) return "left";
        return "";
      });
    }

    function isMarkdownTableSeparator(line) {
      const cells = splitMarkdownTableRow(line);
      return cells.length > 0 && cells.every((cell) => {
        const trimmed = cell.trim();
        if (trimmed.length < 3) return false;
        const core = trimmed.replace(/^:/, "").replace(/:$/, "");
        return /^-+$/.test(core);
      });
    }

    function splitMarkdownTableRow(line) {
      const cells = [];
      let current = "";
      let escaped = false;
      let inCode = false;
      for (const ch of line) {
        if (escaped) {
          current += ch;
          escaped = false;
          continue;
        }
        if (ch === "\\") {
          escaped = true;
          continue;
        }
        if (ch === "`") {
          inCode = !inCode;
          current += ch;
          continue;
        }
        if (ch === "|" && !inCode) {
          cells.push(current.trim());
          current = "";
          continue;
        }
        current += ch;
      }
      if (escaped) current += "\\";
      cells.push(current.trim());
      if (cells[0] === "") cells.shift();
      if (cells[cells.length - 1] === "") cells.pop();
      return cells;
    }

    function renderInline(text) {
      const esc = escapeHTML(text);
      const html = esc
        .replace(/!\[([^\]]*)\]\(([^)]+)\)/g, (_, alt, src) => {
          if (/^https?:/.test(src) || (src.startsWith("/") && !src.startsWith("/Users/"))) return `<img class="inline-image" src="${src}" alt="${alt}">`;
          return `<img class="inline-image" src="${fileRawURL(src)}" alt="${alt}">`;
        })
        .replace(/\[([^\]]+)\]\(([^)]+)\)/g, (_, label, href) => {
          if (/^https?:\/\//.test(href)) return `<a href="${href}" target="_blank" rel="noopener">${label}</a>`;
          if (/^(?:file:\/\/)?(?:\/Users\/|~\/)/.test(href)) {
            const path = href.replace(/^file:\/\//, "");
            return `<a href="${filePreviewURL(path)}" target="_blank" rel="noopener">${label}</a>`;
          }
          if (href.startsWith("/preview") || href.startsWith("/api/")) return `<a href="${href}" target="_blank" rel="noopener">${label}</a>`;
          return `<a href="${filePreviewURL(href)}" target="_blank" rel="noopener">${label}</a>`;
        })
        .replace(/`([^`]+)`/g, "<code>$1</code>")
        .replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>")
        .replace(/_([^_]+)_/g, "<em>$1</em>")
        .replace(/\*([^*]+)\*/g, "<em>$1</em>");
      return linkBareFilePaths(html);
    }

    function filePreviewURL(path) {
      const params = new URLSearchParams({ path: String(path || "") });
      if (state.selectedWorkspaceId) params.set("workspaceID", state.selectedWorkspaceId);
      return `/preview?${params.toString()}`;
    }

    function fileRawURL(path) {
      const params = new URLSearchParams({ path: String(path || "") });
      if (state.selectedWorkspaceId) params.set("workspaceID", state.selectedWorkspaceId);
      return `/api/files/raw?${params.toString()}`;
    }

    function linkBareFilePaths(html) {
      const parts = String(html || "").split(/(<[^>]+>)/g);
      let insideCode = false;
      return parts.map((part) => {
        if (!part) return "";
        if (part.startsWith("<")) {
          if (/^<code\b/i.test(part)) insideCode = true;
          if (/^<\/code>/i.test(part)) insideCode = false;
          return part;
        }
        if (insideCode) return part;
        return autoLinkFilePathText(part);
      }).join("");
    }

    function autoLinkFilePathText(text) {
      const fileExt = "(?:png|jpe?g|gif|webp|svg|pdf|txt|log|md|markdown|html?|json|csv|tsv|diff|patch|swift|js|ts|tsx|jsx|py|sh|zsh|bash|yaml|yml|xml|plist|zip|mp4|mov|m4a|wav|mp3)";
      const absolute = `(?:file:\\/\\/)?(?:\\/Users\\/|~\\/)[^\\n<>"']+?\\.${fileExt}`;
      const relative = `(?:(?:\\.\\.?\\/)?[A-Za-z0-9._-]+\\/)[A-Za-z0-9._\\/ -]+?\\.${fileExt}`;
      const re = new RegExp(`(^|[\\s(\\[{])(${absolute}|${relative})(?=$|[\\s),.;:!?\\]}])`, "gi");
      return String(text || "").replace(re, (_match, prefix, rawPath) => {
        const clean = rawPath.replace(/^file:\/\//, "");
        const href = filePreviewURL(clean);
        const label = shortPath(clean);
        return `${prefix}<a class="local-file-link" href="${href}" target="_blank" rel="noopener" title="${escapeHTML(clean)}">${escapeHTML(label)}</a>`;
      });
    }

    function renderCodeBlockWrapper(code, lang) {
      const id = "cb-" + Math.random().toString(36).slice(2);
      const highlighted = highlightCode(code, lang);
      return `<div class="code-block"><div class="code-block-head"><span class="code-block-lang">${escapeHTML(lang || "plain")}</span><button class="code-copy" data-copy-target="${id}" type="button"><svg viewBox="0 0 24 24" width="12" height="12" aria-hidden="true"><path fill="currentColor" d="M16 1H4C2.9 1 2 1.9 2 3v14h2V3h12zm3 4H8C6.9 5 6 5.9 6 7v14c0 1.1.9 2 2 2h11c1.1 0 2-.9 2-2V7c0-1.1-.9-2-2-2m0 16H8V7h11z"/></svg>Copiar</button></div><pre><code id="${id}">${highlighted}</code></pre></div>`;
    }

    document.addEventListener("click", (e) => {
      const btn = e.target.closest(".code-copy");
      if (!btn) return;
      const target = document.getElementById(btn.dataset.copyTarget);
      if (target) {
        navigator.clipboard?.writeText(target.innerText).then(() => {
          btn.innerHTML = `<svg viewBox="0 0 24 24" width="12" height="12" aria-hidden="true"><path fill="currentColor" d="M9 16.2 4.8 12l-1.4 1.4L9 19 21 7l-1.4-1.4z"/></svg>Copiado`;
          setTimeout(() => { btn.innerHTML = `<svg viewBox="0 0 24 24" width="12" height="12" aria-hidden="true"><path fill="currentColor" d="M16 1H4C2.9 1 2 1.9 2 3v14h2V3h12zm3 4H8C6.9 5 6 5.9 6 7v14c0 1.1.9 2 2 2h11c1.1 0 2-.9 2-2V7c0-1.1-.9-2-2-2m0 16H8V7h11z"/></svg>Copiar`; }, 1200);
        }).catch(() => {});
      }
    });

    // ===== Lightweight syntax highlighting =====
    const HL_KEYWORDS = new Set([
      "if","else","for","while","do","switch","case","break","continue","return","function","const","let","var",
      "class","extends","import","from","export","default","new","this","super","typeof","instanceof","void","in","of",
      "async","await","yield","try","catch","finally","throw","public","private","protected","static","struct","enum",
      "interface","type","namespace","implements","override","nil","None","True","False","def","lambda","self","pass",
      "print","log","guard","let","var","func","fileprivate","internal","open","final","weak","unowned","swift","as","is",
      "package","use","match","fn","mut","where","with","end","then"
    ]);

    function highlightCode(code, lang) {
      const l = (lang || "").toLowerCase();
      if (l === "diff" || looksLikeDiff(code)) return highlightDiffInline(code);
      const escaped = escapeHTML(code);
      // Order matters: comments, strings, numbers, keywords, functions
      let out = escaped;
      out = out.replace(/(\/\*[\s\S]*?\*\/|\/\/[^\n]*|#[^\n]*|;[^\n]*)/g, '<span class="tok-cmt">$1</span>');
      out = out.replace(/(&quot;(?:\\.|[^&\\])*?&quot;|&#039;(?:\\.|[^&\\])*?&#039;|`(?:[^`])*?`)/g, '<span class="tok-str">$1</span>');
      out = out.replace(/\b(\d[\d_]*(?:\.\d+)?)\b/g, '<span class="tok-num">$1</span>');
      out = out.replace(/\b([A-Za-z_][A-Za-z0-9_]*)\b/g, (m, w) => {
        if (HL_KEYWORDS.has(w)) return `<span class="tok-kw">${w}</span>`;
        if (/^[A-Z]/.test(w)) return `<span class="tok-ty">${w}</span>`;
        return w;
      });
      out = out.replace(/\b([A-Za-z_][A-Za-z0-9_]*)(?=\()/g, '<span class="tok-fn">$1</span>');
      return out;
    }

    function highlightDiffInline(code) {
      return code.split("\n").map((l) => {
        const esc = escapeHTML(l);
        if (l.startsWith("+")) return `<span class="tok-str">${esc}</span>`;
        if (l.startsWith("-")) return `<span class="tok-num">${esc}</span>`;
        if (l.startsWith("@") || l.startsWith("diff")) return `<span class="tok-kw">${esc}</span>`;
        return esc;
      }).join("\n");
    }

    // ===== Toast =====
    function toast(message, kind = "info", duration = 2600) {
      const el = document.createElement("div");
      el.className = "toast";
      el.dataset.kind = kind;
      el.textContent = message;
      els.toastStack.appendChild(el);
      setTimeout(() => {
        el.style.opacity = "0";
        el.style.transform = "translateY(6px)";
        setTimeout(() => el.remove(), 220);
      }, duration);
    }

    // ===== API helper =====
    async function api(path, { method = "GET", json, body, headers } = {}) {
      const init = { method, headers: { "Accept": "application/json", ...(headers || {}) } };
      if (json !== undefined) {
        init.headers["Content-Type"] = "application/json";
        init.body = JSON.stringify(json);
      } else if (body !== undefined) {
        init.body = body;
      }
      const res = await fetch(API_BASE + path, init);
      const ct = res.headers.get("content-type") || "";
      let payload = null;
      if (ct.includes("application/json")) {
        try { payload = await res.json(); } catch { payload = null; }
      } else {
        payload = await res.text();
      }
      if (!res.ok) {
        const message = (payload && payload.error) || res.statusText || `HTTP ${res.status}`;
        const err = new Error(message);
        err.status = res.status;
        err.payload = payload;
        throw err;
      }
      return payload;
    }

    // ===== Utility =====
    function escapeHTML(text) {
      return String(text ?? "")
        .replace(/&/g, "&amp;")
        .replace(/</g, "&lt;")
        .replace(/>/g, "&gt;")
        .replace(/"/g, "&quot;")
        .replace(/'/g, "&#039;");
    }

    function shortPath(path) {
      const parts = String(path || "").split("/");
      if (parts.length <= 3) return path;
      return parts.slice(-3).join("/");
    }

    function vibrate(pattern) {
      if (!HAS_VIBRATE || !IS_TOUCH) return;
      try { navigator.vibrate(pattern); } catch {}
    }

    function resetTitle() { document.title = state.titleOriginal; }

    function loadJSON(key, fallback) {
      try { const v = localStorage.getItem(key); return v ? JSON.parse(v) : fallback; }
      catch { return fallback; }
    }

    function saveJSON(key, value) {
      try { localStorage.setItem(key, JSON.stringify(value)); } catch {}
    }

    function handleLaunchIntent() {
      try {
        const params = new URLSearchParams(window.location.search);
        if (params.get("action") === "new") {
          startNewSession();
          history.replaceState({}, "", "/");
        }
      } catch {}
    }

    function showFatalError(err) {
      const message = err?.message || String(err || "Error desconocido");
      els.chatStream.innerHTML = "";
      const inner = document.createElement("div");
      inner.className = "stage-inner";
      const box = document.createElement("div");
      box.className = "stage-error";
      box.innerHTML = `<strong>Algo no va bien</strong><span>${escapeHTML(message)}</span>`;
      inner.appendChild(box);
      els.chatStream.appendChild(inner);
    }
    """#

    static let serviceWorkerJavaScript = #"""
    const CACHE = "miwhisper-companion-v55";
    const ASSETS = ["/", "/app.css", "/app.js", "/manifest.webmanifest", "/app-icon.png"];

    self.addEventListener("install", (event) => {
      event.waitUntil(
        caches.open(CACHE).then((cache) => cache.addAll(ASSETS)).catch(() => {})
      );
      self.skipWaiting();
    });

    self.addEventListener("activate", (event) => {
      event.waitUntil(
        caches.keys().then((keys) => Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k))))
      );
      self.clients.claim();
    });

    self.addEventListener("fetch", (event) => {
      if (event.request.method !== "GET") return;
      if (event.request.url.includes("/api/")) return;
      event.respondWith(
        fetch(event.request)
          .then((response) => {
            if (response.ok) {
              const copy = response.clone();
              caches.open(CACHE).then((cache) => cache.put(event.request, copy)).catch(() => {});
            }
            return response;
          })
          .catch(() => caches.match(event.request))
      );
    });
    """#
}

final class AppleTouchIconCache: @unchecked Sendable {
    let data: Data

    init() {
        self.data = AppleTouchIconCache.renderAppIcon(size: 180)
    }

    static func renderAppIcon(size: Int) -> Data {
        let width = max(64, size)
        let height = max(64, size)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return Data()
        }

        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        let previousContext = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath).draw(in: rect)
        NSGraphicsContext.current = previousContext

        guard let cgImage = ctx.makeImage() else { return Data() }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        rep.size = NSSize(width: width, height: height)
        return rep.representation(using: .png, properties: [:]) ?? Data()
    }
}
