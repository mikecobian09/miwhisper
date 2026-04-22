import AppKit
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
}

struct CompanionSessionDetail: Codable {
    let session: CompanionSessionSummary
    let activity: [CodexActivityEntry]
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

    private init() {}

    func start() {
        guard server == nil else { return }

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
            try httpServer.start()
            server = httpServer
            NSLog("[MiWhisper][Companion] listening on http://127.0.0.1:%d", port)
        } catch {
            NSLog("[MiWhisper][Companion] failed to start server error=%@", error.localizedDescription)
        }
    }

    func stop() {
        server?.stop()
        server = nil
    }

    var localURLString: String {
        "http://127.0.0.1:\(port)"
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
            return .json(["ok": true, "port": port, "localURL": localURLString], cacheControl: "no-store")

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

        case ("POST", "/api/sessions"):
            return await createSession(request: request)

        case ("POST", "/api/sessions/open-thread"):
            return await openThreadSession(request: request)

        case ("POST", let path) where path.hasPrefix("/api/sessions/") && path.hasSuffix("/messages"):
            return await continueSession(request: request)

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
        let shouldOpenWindow = body["openWindow"] as? Bool ?? false

        let recordID = CodexSessionManager.shared.createSession(
            prompt: prompt,
            executablePath: AppState.shared.codexPath,
            workingDirectory: workspace.path,
            modelOverride: modelOverride?.isEmpty == false ? modelOverride : AppState.shared.codexDefaultModel,
            reasoningEffort: reasoning ?? AppState.shared.codexReasoningEffort,
            serviceTier: serviceTier ?? AppState.shared.codexServiceTier,
            shouldPresentWindow: shouldOpenWindow
        )

        if let record = CodexSessionManager.shared.sessionRecord(id: recordID) {
            do {
                try CodexSessionManager.shared.send(prompt: prompt, to: record.id)
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

        let recordID = CodexSessionManager.shared.openThread(
            threadID: threadID,
            title: entry.title,
            workingDirectory: entry.workingDirectory,
            executablePath: AppState.shared.codexPath,
            modelOverride: modelOverride?.isEmpty == false ? modelOverride : nil,
            reasoningEffort: reasoning,
            serviceTier: serviceTier
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

        do {
            try CodexSessionManager.shared.send(prompt: prompt, to: recordID)
        } catch {
            return .json(["error": error.localizedDescription], status: 500)
        }

        guard let detail = sessionDetail(for: recordID) else {
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
                    guard let detail = CompanionBridge.shared.sessionDetail(for: recordID, workspaces: []) else {
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

        let fileURL = URL(fileURLWithPath: path).standardizedFileURL
        guard isAllowedFile(url: fileURL) else {
            return .json(["error": "Path is outside the allowed roots"], status: 403)
        }

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return .json(["error": "File not found"], status: 404)
        }

        do {
            let data = try Data(contentsOf: fileURL)
            return .binary(
                data,
                status: 200,
                contentType: CompanionFileMimeType.contentType(for: fileURL),
                cacheControl: "no-store"
            )
        } catch {
            return .json(["error": error.localizedDescription], status: 500)
        }
    }

    private func renderedPreview(request: CompanionHTTPRequest) async -> CompanionHTTPResponse {
        guard let path = request.queryValue(named: "path"), !path.isEmpty else {
            return .json(["error": "Missing path"], status: 400)
        }

        let fileURL = URL(fileURLWithPath: path).standardizedFileURL
        guard isAllowedFile(url: fileURL) else {
            return .json(["error": "Path is outside the allowed roots"], status: 403)
        }

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
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

        if ["png", "jpg", "jpeg", "gif", "svg", "webp", "pdf", "txt", "log", "diff", "patch"].contains(fileExtension) {
            return .redirect(location: "/api/files/raw?path=\(path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? path)")
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

    private func sessionDetail(for recordID: UUID) -> CompanionSessionDetail? {
        let workspaces = availableWorkspaces()
        return sessionDetail(for: recordID, workspaces: workspaces)
    }

    private func sessionDetail(
        for recordID: UUID,
        workspaces: [CompanionWorkspaceDescriptor]
    ) -> CompanionSessionDetail? {
        CodexSessionManager.shared.hydrateSavedThreadIfNeeded(recordID: recordID)

        guard let record = CodexSessionManager.shared.sessionRecord(id: recordID) else {
            return nil
        }
        return CompanionSessionDetail(
            session: summary(for: record, workspaces: workspaces),
            activity: companionActivity(for: record)
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

    private func summary(
        for record: CodexSessionRecord,
        workspaces: [CompanionWorkspaceDescriptor]
    ) -> CompanionSessionSummary {
        let workspaceName = workspaces.first(where: { record.workingDirectory.hasPrefix($0.path) })?.name
            ?? workspaces.first(where: { record.workingDirectory == $0.path })?.name
            ?? URL(fileURLWithPath: record.workingDirectory).lastPathComponent
        let workspaceID = workspaces.first(where: { record.workingDirectory == $0.path || record.workingDirectory.hasPrefix($0.path + "/") })?.id

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
            hasLocalSession: true
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
            hasLocalSession: entry.recordID != nil
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

    private func isAllowedFile(url: URL) -> Bool {
        let filePath = url.standardizedFileURL.path
        return allowedRoots().contains(where: { root in
            filePath == root || filePath.hasPrefix(root + "/")
        })
    }

    private func recordID(fromSessionActionPath path: String, suffix: String) -> UUID? {
        let prefix = "/api/sessions/"
        guard path.hasPrefix(prefix), path.hasSuffix(suffix) else { return nil }
        let rawValue = String(path.dropFirst(prefix.count).dropLast(suffix.count))
        return UUID(uuidString: rawValue)
    }

    private static func parseReasoningEffort(_ rawValue: String?) -> CodexReasoningEffort? {
        guard let rawValue else { return nil }
        return CodexReasoningEffort(rawValue: rawValue)
    }

    private static func parseServiceTier(_ rawValue: String?) -> CodexServiceTier? {
        guard let rawValue else { return nil }
        return CodexServiceTier(rawValue: rawValue)
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
    static func contentType(for fileURL: URL) -> String {
        switch fileURL.pathExtension.lowercased() {
        case "html", "htm":
            return "text/html; charset=utf-8"
        case "css":
            return "text/css; charset=utf-8"
        case "js":
            return "application/javascript; charset=utf-8"
        case "json", "webmanifest":
            return "application/json; charset=utf-8"
        case "md", "markdown", "txt", "log", "diff", "patch":
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
              --bg: #f3efe7;
              --panel: rgba(255,255,255,0.88);
              --text: #1f2937;
              --muted: #5f6b7a;
              --accent: #2563eb;
              --border: rgba(15, 23, 42, 0.12);
            }
            @media (prefers-color-scheme: dark) {
              :root {
                --bg: #111827;
                --panel: rgba(17,24,39,0.86);
                --text: #f3f4f6;
                --muted: #cbd5e1;
                --border: rgba(148, 163, 184, 0.2);
              }
            }
            body {
              margin: 0;
              padding: 24px;
              font: 16px/1.65 "Avenir Next", ui-rounded, system-ui, sans-serif;
              color: var(--text);
              background:
                radial-gradient(circle at top right, rgba(13,148,136,0.16), transparent 34%),
                radial-gradient(circle at bottom left, rgba(245,158,11,0.12), transparent 28%),
                var(--bg);
            }
            article {
              max-width: 920px;
              margin: 0 auto;
              padding: 28px;
              border: 1px solid var(--border);
              border-radius: 24px;
              background: var(--panel);
              backdrop-filter: blur(14px);
              box-shadow: 0 28px 60px rgba(15, 23, 42, 0.14);
            }
            pre, code {
              font-family: "SF Mono", "IBM Plex Mono", ui-monospace, monospace;
            }
            pre {
              overflow-x: auto;
              padding: 14px 16px;
              border-radius: 16px;
              background: rgba(15, 23, 42, 0.08);
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

        for line in lines {
            if line.hasPrefix("```") {
                if inCodeFence {
                    flushCodeFence()
                } else {
                    flushParagraph()
                    flushList()
                }
                inCodeFence.toggle()
                continue
            }

            if inCodeFence {
                codeFenceLines.append(line)
                continue
            }

            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flushParagraph()
                flushList()
                continue
            }

            if let headingLevel = headingLevel(for: line) {
                flushParagraph()
                flushList()
                let text = line.drop { $0 == "#" || $0 == " " }
                html.append("<h\(headingLevel)>\(inline(String(text)))</h\(headingLevel)>")
                continue
            }

            if line.hasPrefix(">") {
                flushParagraph()
                flushList()
                let text = line.drop { $0 == ">" || $0 == " " }
                html.append("<blockquote>\(inline(String(text)))</blockquote>")
                continue
            }

            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                flushParagraph()
                listItems.append(String(line.dropFirst(2)))
                continue
            }

            paragraphLines.append(line.trimmingCharacters(in: .whitespaces))
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
        cacheControl: String = "no-store"
    ) -> CompanionHTTPResponse {
        CompanionHTTPResponse(
            status: status,
            contentType: contentType,
            headers: ["Cache-Control": cacheControl],
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
    static func manifest(port: Int) -> [String: Any] {
        [
            "name": "MiWhisper Chat",
            "short_name": "MiWhisper",
            "display": "standalone",
            "display_override": ["standalone", "minimal-ui"],
            "orientation": "portrait-primary",
            "start_url": "/",
            "scope": "/",
            "background_color": "#faf9f6",
            "theme_color": "#2563eb",
            "description": "Beautiful Codex chat bridge for MiWhisper running on your Mac.",
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
          <stop offset="0" stop-color="#38bdf8"/>
          <stop offset="1" stop-color="#2563eb"/>
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
          <stop offset="0" stop-color="#38bdf8"/>
          <stop offset="1" stop-color="#2563eb"/>
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
      <meta name="theme-color" content="#f8fafc" media="(prefers-color-scheme: light)">
      <meta name="theme-color" content="#0b1220" media="(prefers-color-scheme: dark)">
      <meta name="apple-mobile-web-app-capable" content="yes">
      <meta name="apple-mobile-web-app-status-bar-style" content="default">
      <meta name="apple-mobile-web-app-title" content="MiWhisper">
      <meta name="color-scheme" content="light dark">
      <title>MiWhisper Chat</title>
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
                  <span class="brand-subtitle">Codex companion</span>
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
              <span class="footer-text">Local bridge · <code>127.0.0.1:6009</code></span>
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
            <div class="composer" id="composer-shell">
              <button class="mic-button" id="voice-button" type="button" aria-label="Grabar voz" title="Mantén pulsado para grabar">
                <svg class="mic-icon" viewBox="0 0 24 24" width="22" height="22" aria-hidden="true"><path fill="currentColor" d="M12 14a3 3 0 0 0 3-3V6a3 3 0 0 0-6 0v5a3 3 0 0 0 3 3zm5-3a5 5 0 0 1-10 0H5a7 7 0 0 0 6 6.92V21h2v-3.08A7 7 0 0 0 19 11z"/></svg>
                <span class="mic-timer" id="mic-timer" hidden>0:00</span>
              </button>
              <textarea id="composer" rows="1" placeholder="Escribe, dicta o usa /slash y @archivo…" autocomplete="off" autocorrect="on" spellcheck="true" enterkeyhint="send"></textarea>
              <button class="send-button" id="send-button" type="button" aria-label="Enviar">
                <svg viewBox="0 0 24 24" width="20" height="20" aria-hidden="true"><path fill="currentColor" d="m3.4 20.4 17.45-7.48a1 1 0 0 0 0-1.84L3.4 3.6a1 1 0 0 0-1.38 1.17L4.2 11 12 12l-7.8 1-2.18 6.23a1 1 0 0 0 1.38 1.17z"/></svg>
              </button>
            </div>
            <p class="composer-hint" id="composer-hint">Enter envía · Shift + Enter salto · ⌘↵ también envía · ⌘K paleta · / comandos · @ archivos</p>
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
      --canvas: #f8fafc;
      --canvas-strong: #eef4fb;
      --surface: #ffffff;
      --surface-muted: #f1f5f9;
      --surface-sunk: #e8eef7;
      --surface-hover: #f5f8fc;
      --border: rgba(17, 24, 39, 0.08);
      --border-strong: rgba(17, 24, 39, 0.14);
      --text: #111827;
      --text-soft: #374151;
      --text-muted: #6b7280;
      --text-faint: #9ca3af;
      --accent: #2563eb;
      --accent-strong: #1d4ed8;
      --accent-soft: #dbeafe;
      --accent-tint: #bfdbfe;
      --danger: #dc2626;
      --danger-soft: #fee2e2;
      --warning: #d97706;
      --success: #16a34a;
      --user-bubble-bg: #111827;
      --user-bubble-fg: #ffffff;
      --shadow-sm: 0 1px 2px rgba(17, 24, 39, 0.05);
      --shadow-md: 0 6px 18px rgba(17, 24, 39, 0.07);
      --shadow-lg: 0 18px 42px rgba(17, 24, 39, 0.12);
      --shadow-palette: 0 20px 80px rgba(15, 23, 42, 0.2);
      --radius-sm: 8px;
      --radius-md: 12px;
      --radius-lg: 16px;
      --radius-xl: 20px;
      --radius-pill: 999px;
      --sans: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Inter", "Segoe UI", system-ui, sans-serif;
      --mono: ui-monospace, SFMono-Regular, "SF Mono", "JetBrains Mono", Menlo, monospace;
      --focus: 0 0 0 3px rgba(37, 99, 235, 0.28);
      --code-bg: #0f172a;
      --code-fg: #e2e8f0;
      --diff-add-bg: rgba(22, 163, 74, 0.12);
      --diff-add-fg: #15803d;
      --diff-del-bg: rgba(220, 38, 38, 0.10);
      --diff-del-fg: #b91c1c;
      --diff-hunk-bg: rgba(124, 58, 237, 0.10);
      --diff-hunk-fg: #6d28d9;
      --syntax-keyword: #c084fc;
      --syntax-string: #86efac;
      --syntax-number: #fbbf24;
      --syntax-comment: #94a3b8;
      --syntax-func: #60a5fa;
      --syntax-type: #f472b6;
    }

    :root[data-theme="dark"] {
      color-scheme: dark;
      --canvas: #0b1220;
      --canvas-strong: #0a0f1b;
      --surface: #111a2e;
      --surface-muted: #0f172a;
      --surface-sunk: #0a1222;
      --surface-hover: #172439;
      --border: rgba(148, 163, 184, 0.14);
      --border-strong: rgba(148, 163, 184, 0.24);
      --text: #f1f5f9;
      --text-soft: #cbd5e1;
      --text-muted: #94a3b8;
      --text-faint: #64748b;
      --accent: #60a5fa;
      --accent-strong: #3b82f6;
      --accent-soft: rgba(96, 165, 250, 0.14);
      --accent-tint: rgba(96, 165, 250, 0.28);
      --danger: #f87171;
      --danger-soft: rgba(248, 113, 113, 0.15);
      --warning: #fbbf24;
      --success: #4ade80;
      --user-bubble-bg: #e2e8f0;
      --user-bubble-fg: #0b1220;
      --shadow-sm: 0 1px 2px rgba(0, 0, 0, 0.4);
      --shadow-md: 0 10px 28px rgba(0, 0, 0, 0.45);
      --shadow-lg: 0 24px 56px rgba(0, 0, 0, 0.55);
      --shadow-palette: 0 20px 80px rgba(0, 0, 0, 0.7);
      --code-bg: #020617;
      --code-fg: #e2e8f0;
      --diff-add-bg: rgba(74, 222, 128, 0.14);
      --diff-add-fg: #86efac;
      --diff-del-bg: rgba(248, 113, 113, 0.14);
      --diff-del-fg: #fca5a5;
      --diff-hunk-bg: rgba(167, 139, 250, 0.14);
      --diff-hunk-fg: #c4b5fd;
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
      grid-template-columns: 276px minmax(0, 1fr);
      width: 100%;
      max-width: 100vw;
      height: 100dvh;
      min-height: 100dvh;
      overflow-x: hidden;
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
      gap: 10px;
      padding: 12px 10px 10px;
      background: var(--surface-muted);
      border-right: 1px solid var(--border);
    }

    .drawer-header {
      display: flex;
      justify-content: space-between;
      align-items: center;
      padding: 0 2px;
    }

    .drawer-close { display: none; }

    .brand { display: flex; align-items: center; gap: 8px; min-width: 0; }

    .brand-mark {
      width: 32px; height: 32px;
      border-radius: 9px;
      object-fit: cover;
      box-shadow: 0 6px 14px rgba(37, 99, 235, 0.18);
      flex-shrink: 0;
    }

    .brand-text { display: grid; line-height: 1.15; }
    .brand-title { font-weight: 700; font-size: 0.92rem; }
    .brand-subtitle { font-size: 0.7rem; color: var(--text-muted); }

    .drawer-label {
      font-size: 0.64rem;
      text-transform: uppercase;
      letter-spacing: 0.1em;
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
      border-radius: 10px;
      background: linear-gradient(180deg, var(--accent) 0%, var(--accent-strong) 100%);
      color: #fff;
      border: none;
      font-weight: 600;
      font-size: 0.86rem;
      cursor: pointer;
      box-shadow: 0 8px 16px rgba(37, 99, 235, 0.20);
      transition: transform 120ms ease, box-shadow 120ms ease, filter 120ms ease;
    }
    .primary-button:hover { transform: translateY(-1px); filter: brightness(1.04); }
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
      background: rgba(255,255,255,0.18);
      border-color: rgba(255,255,255,0.28);
      color: #fff;
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
      border-radius: var(--radius-pill);
      font-size: 0.75rem;
      cursor: pointer;
      transition: background 120ms ease, border 120ms ease, color 120ms ease;
    }
    .chip:hover { border-color: var(--border-strong); }
    .chip[data-active="true"] {
      background: var(--accent-soft);
      border-color: var(--accent);
      color: var(--accent-strong);
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
      letter-spacing: 0.12em;
      color: var(--text-faint);
      padding: 8px 5px 2px;
      font-weight: 600;
    }

    .session-item {
      display: grid;
      grid-template-columns: minmax(0, 1fr) auto;
      align-items: center;
      gap: 6px;
      padding: 7px 8px;
      border-radius: 9px;
      cursor: pointer;
      color: var(--text-soft);
      text-align: left;
      border: 1px solid transparent;
      background: transparent;
      transition: background 120ms ease, border 120ms ease, color 120ms ease;
      min-width: 0;
    }
    .session-item:hover { background: var(--surface); border-color: var(--border); color: var(--text); }
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
      font-weight: 600;
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
    .session-item-pin svg { color: var(--accent); }
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
      50% { box-shadow: 0 0 0 5px rgba(37, 99, 235, 0); }
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
      grid-template-rows: auto minmax(0, 1fr) auto;
      min-width: 0;
      min-height: 0;
      max-width: 100vw;
      overflow-x: hidden;
      background: var(--canvas);
    }

    .topbar {
      display: flex;
      align-items: center;
      gap: 8px;
      min-width: 0;
      padding: 9px 14px;
      border-bottom: 1px solid var(--border);
      background: linear-gradient(180deg, var(--canvas) 0%, rgba(248, 250, 252, 0) 100%);
      backdrop-filter: saturate(120%) blur(8px);
      -webkit-backdrop-filter: saturate(120%) blur(8px);
      position: sticky;
      top: 0;
      z-index: 20;
    }
    :root[data-theme="dark"] .topbar {
      background: linear-gradient(180deg, var(--canvas) 0%, rgba(11, 18, 32, 0) 100%);
    }

    .icon-button {
      background: transparent;
      border: 1px solid var(--border);
      color: var(--text-soft);
      width: 34px; height: 34px;
      border-radius: 9px;
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

    #menu-button { display: none; }

    .topbar-title {
      flex: 1;
      min-width: 0;
      display: grid;
      line-height: 1.2;
    }
    .topbar-title h1 {
      font-size: 1.05rem;
      font-weight: 700;
      white-space: nowrap;
      overflow: hidden;
      text-overflow: ellipsis;
      letter-spacing: -0.01em;
      cursor: text;
    }
    .topbar-title h1[contenteditable="true"] {
      outline: 1px dashed var(--border-strong);
      outline-offset: 4px;
      border-radius: 6px;
      cursor: text;
    }
    .topbar-subtitle {
      font-size: 0.78rem;
      color: var(--text-muted);
      white-space: nowrap;
      overflow: hidden;
      text-overflow: ellipsis;
    }

    .topbar-actions { display: flex; gap: 5px; flex-shrink: 0; min-width: 0; }

    /* ===== Chat stream ===== */
    .chat-stream {
      overflow-y: auto;
      overflow-x: hidden;
      padding: 14px max(14px, env(safe-area-inset-right)) 82px max(14px, env(safe-area-inset-left));
      scroll-behavior: smooth;
      scroll-padding-block-end: 92px;
      overscroll-behavior: contain;
      min-width: 0;
      max-width: 100%;
    }
    .chat-stream:focus { outline: none; }

    .stage-inner {
      width: min(940px, 100%);
      max-width: 940px;
      margin: 0 auto;
      display: grid;
      gap: 12px;
      min-width: 0;
    }

    /* Empty state */
    .empty-state {
      display: grid;
      gap: 10px;
      width: min(640px, 100%);
      max-width: 640px;
      margin: 28px auto 0;
      text-align: center;
      animation: fade-in 280ms ease-out;
    }
    .empty-state h2 {
      font-size: 1.22rem;
      letter-spacing: -0.015em;
      font-weight: 700;
    }
    .empty-state p {
      color: var(--text-muted);
      line-height: 1.42;
      font-size: 0.9rem;
    }
    .empty-hero {
      display: grid;
      place-items: center;
      gap: 8px;
      padding: 8px 0 4px;
    }
    .empty-hero-mark {
      width: 58px; height: 58px;
      border-radius: 16px;
      object-fit: cover;
      box-shadow: 0 10px 24px rgba(37, 99, 235, 0.18);
    }

    .suggestion-grid {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));
      gap: 8px;
      margin-top: 8px;
      min-width: 0;
    }
    .suggestion-card {
      padding: 10px 12px;
      background: var(--surface);
      border: 1px solid var(--border);
      border-radius: var(--radius-sm);
      cursor: pointer;
      text-align: left;
      display: grid;
      gap: 4px;
      color: var(--text-soft);
      transition: transform 140ms ease, border 140ms ease, box-shadow 140ms ease;
    }
    .suggestion-card:hover {
      transform: translateY(-2px);
      border-color: var(--border-strong);
      box-shadow: var(--shadow-sm);
    }
    .suggestion-card strong { color: var(--text); font-weight: 600; font-size: 0.92rem; }
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
      max-width: 720px;
      min-width: 0;
    }
    .segment-user.segment-optimistic { opacity: 0.78; }
    .segment-user.segment-failed { opacity: 0.9; }

    .user-bubble {
      background: var(--user-bubble-bg);
      color: var(--user-bubble-fg);
      padding: 8px 11px;
      border-radius: 14px 14px 5px 14px;
      font-size: 0.92rem;
      line-height: 1.42;
      box-shadow: none;
      max-width: min(88vw, 720px);
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
      gap: 7px;
      padding: 10px 12px;
      background: var(--surface);
      border: 1px solid var(--border);
      border-radius: var(--radius-md);
      box-shadow: none;
      overflow: hidden;
      min-width: 0;
      max-width: 100%;
    }
    .assistant-block.is-final {
      border-color: rgba(37, 99, 235, 0.18);
      background:
        linear-gradient(180deg, rgba(37, 99, 235, 0.045), transparent 80px),
        var(--surface);
    }
    :root[data-theme="dark"] .assistant-block.is-final {
      border-color: rgba(96, 165, 250, 0.24);
      background:
        linear-gradient(180deg, rgba(96, 165, 250, 0.08), transparent 88px),
        var(--surface);
    }

    .assistant-block-header {
      display: flex;
      align-items: center;
      gap: 7px;
      flex-wrap: wrap;
      font-size: 0.72rem;
      color: var(--text-muted);
    }
    .assistant-avatar {
      width: 24px; height: 24px;
      border-radius: 7px;
      object-fit: cover;
      flex-shrink: 0;
    }
    .kind-chip {
      display: inline-flex;
      align-items: center;
      gap: 4px;
      padding: 1px 6px;
      border-radius: var(--radius-pill);
      font-size: 0.62rem;
      font-weight: 600;
      letter-spacing: 0.02em;
      text-transform: uppercase;
      background: var(--surface-sunk);
      color: var(--text-soft);
      border: 1px solid var(--border);
    }
    .kind-reasoning { background: rgba(124, 58, 237, 0.08); color: #6d28d9; border-color: rgba(124, 58, 237, 0.15); }
    .kind-command { background: rgba(245, 158, 11, 0.10); color: #a16207; border-color: rgba(245, 158, 11, 0.18); }
    .kind-patch { background: rgba(34, 197, 94, 0.10); color: #15803d; border-color: rgba(34, 197, 94, 0.18); }
    .kind-final { background: var(--accent-soft); color: var(--accent-strong); border-color: rgba(37, 99, 235, 0.18); }
    .kind-tool { background: rgba(99, 102, 241, 0.10); color: #4338ca; border-color: rgba(99, 102, 241, 0.18); }
    .kind-system { background: rgba(100, 116, 139, 0.10); color: #475569; border-color: rgba(100, 116, 139, 0.18); }

    :root[data-theme="dark"] .kind-reasoning { background: rgba(167, 139, 250, 0.12); color: #c4b5fd; border-color: rgba(167, 139, 250, 0.22); }
    :root[data-theme="dark"] .kind-command { background: rgba(251, 191, 36, 0.12); color: #fcd34d; border-color: rgba(251, 191, 36, 0.22); }
    :root[data-theme="dark"] .kind-patch { background: rgba(74, 222, 128, 0.12); color: #86efac; border-color: rgba(74, 222, 128, 0.22); }
    :root[data-theme="dark"] .kind-final { background: rgba(45, 212, 191, 0.14); color: #5eead4; border-color: rgba(45, 212, 191, 0.28); }
    :root[data-theme="dark"] .kind-tool { background: rgba(129, 140, 248, 0.14); color: #a5b4fc; border-color: rgba(129, 140, 248, 0.24); }
    :root[data-theme="dark"] .kind-system { background: rgba(148, 163, 184, 0.14); color: #cbd5e1; border-color: rgba(148, 163, 184, 0.22); }

    .assistant-title {
      font-weight: 700;
      font-size: 0.9rem;
      color: var(--text);
      letter-spacing: -0.01em;
    }

    .assistant-body {
      color: var(--text-soft);
      font-size: 0.9rem;
      line-height: 1.45;
      overflow-wrap: anywhere;
      min-width: 0;
      max-width: 100%;
    }
    .assistant-body h1, .assistant-body h2, .assistant-body h3 {
      color: var(--text);
      font-weight: 700;
      letter-spacing: -0.01em;
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
      padding: 3px 9px;
      border-left: 3px solid var(--accent);
      background: var(--accent-soft);
      border-radius: 6px;
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
      font-size: 0.82rem;
      margin: 0.5em 0;
      border: 1px solid var(--border);
      border-radius: 8px;
      display: block;
      overflow: hidden;
      overflow-x: auto;
    }
    .assistant-body th, .assistant-body td {
      padding: 5px 8px;
      border-bottom: 1px solid var(--border);
      text-align: left;
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
      border-radius: 10px;
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
      letter-spacing: 0.04em;
      color: #94a3b8;
      background: rgba(15, 23, 42, 0.65);
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
      overflow-x: auto;
      font-family: var(--mono);
      font-size: 0.78rem;
      line-height: 1.42;
      color: var(--code-fg);
      background: transparent;
      border: none;
    }
    .code-block pre code { background: transparent; border: none; padding: 0; color: inherit; font-size: inherit; }

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
      border-radius: 12px;
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
      letter-spacing: 0.05em;
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

    .activity-collapsible {
      margin-top: 6px;
      border: 1px solid var(--border);
      border-radius: 10px;
      background: var(--surface-sunk);
      overflow: hidden;
    }
    .activity-collapsible > summary {
      cursor: pointer;
      list-style: none;
      padding: 7px 10px;
      color: var(--text-muted);
      font-size: 0.78rem;
      font-weight: 650;
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
      padding: 8px;
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
      background: var(--surface-sunk);
      color: var(--text-soft);
      border: 1px solid var(--border);
      border-radius: 10px;
      font-family: var(--mono);
      font-size: 0.78rem;
      cursor: pointer;
      text-decoration: none;
      transition: background 120ms ease, transform 120ms ease;
    }
    .file-card:hover { background: var(--surface); transform: translateY(-1px); }
    .file-card-icon {
      width: 18px; height: 18px;
      border-radius: 5px;
      background: var(--accent-soft);
      color: var(--accent-strong);
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
      border-radius: 12px;
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
      border-radius: 10px;
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
      padding: 9px 12px;
      background: var(--surface);
      border: 1px solid var(--border);
      border-radius: var(--radius-md);
      box-shadow: none;
      color: var(--text-muted);
      font-size: 0.82rem;
      animation: fade-in 200ms ease-out;
    }
    .thinking-dots {
      display: inline-flex;
      gap: 4px;
    }
    .thinking-dots span {
      width: 7px; height: 7px;
      border-radius: 50%;
      background: var(--accent);
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
      color: #fff;
      border-radius: var(--radius-pill);
      font-size: 0.66rem;
      font-weight: 700;
      min-width: 18px;
      height: 18px;
      padding: 0 5px;
      display: inline-grid;
      place-items: center;
      box-shadow: 0 4px 10px rgba(37, 99, 235, 0.32);
    }

    /* Composer dock */
    .composer-dock {
      position: sticky;
      bottom: 0;
      left: 0;
      right: 0;
      padding: 8px max(12px, env(safe-area-inset-right)) calc(10px + env(safe-area-inset-bottom)) max(12px, env(safe-area-inset-left));
      background: linear-gradient(180deg, rgba(248, 250, 252, 0) 0%, var(--canvas) 38%, var(--canvas) 100%);
      z-index: 30;
      min-width: 0;
      max-width: 100%;
      overflow-x: hidden;
    }
    :root[data-theme="dark"] .composer-dock {
      background: linear-gradient(180deg, rgba(11, 18, 32, 0) 0%, var(--canvas) 38%, var(--canvas) 100%);
    }

    .composer {
      position: relative;
      width: min(940px, 100%);
      max-width: 940px;
      margin: 0 auto;
      background: var(--surface);
      border: 1px solid var(--border-strong);
      border-radius: 15px;
      box-shadow: 0 4px 14px rgba(15, 23, 42, 0.08);
      display: grid;
      grid-template-columns: auto minmax(0, 1fr) auto;
      align-items: end;
      padding: 5px;
      gap: 4px;
      min-width: 0;
      transition: border-color 120ms ease, box-shadow 160ms ease;
    }
    .composer:focus-within {
      border-color: var(--accent);
      box-shadow: 0 0 0 3px rgba(37, 99, 235, 0.12), 0 4px 14px rgba(15, 23, 42, 0.08);
    }
    .composer textarea {
      resize: none;
      border: none;
      outline: none;
      padding: 8px 7px;
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
    .composer textarea::placeholder { color: var(--text-faint); }

    .mic-button, .send-button {
      width: 38px; height: 38px;
      border-radius: 11px;
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
    .mic-button:hover { background: var(--border); color: var(--text); }
    .mic-button[data-recording="true"] {
      background: var(--danger);
      color: white;
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
      background: var(--accent);
      color: white;
      box-shadow: 0 6px 14px rgba(37, 99, 235, 0.24);
    }
    .send-button:hover { background: var(--accent-strong); }
    .send-button:disabled { opacity: 0.4; cursor: not-allowed; box-shadow: none; }
    .send-button:active { transform: scale(0.95); }

    .composer-hint {
      width: min(940px, 100%);
      max-width: 940px;
      margin: 4px auto 0;
      text-align: center;
      font-size: 0.66rem;
      color: var(--text-faint);
      overflow: hidden;
      text-overflow: ellipsis;
      white-space: nowrap;
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
      letter-spacing: 0.1em;
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
      background: rgba(15, 23, 42, 0.32);
      backdrop-filter: blur(4px);
      -webkit-backdrop-filter: blur(4px);
      animation: fade-in 160ms ease-out;
    }
    .palette-panel {
      position: relative;
      width: min(620px, calc(100vw - 32px));
      background: var(--surface);
      border: 1px solid var(--border-strong);
      border-radius: 20px;
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
      padding: 14px 16px;
      border-bottom: 1px solid var(--border);
      color: var(--text-muted);
    }
    .palette-search input {
      flex: 1;
      background: transparent;
      border: none;
      outline: none;
      font-size: 1rem;
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
      letter-spacing: 0.12em;
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
      border-radius: 10px;
      cursor: pointer;
      border: none;
      background: transparent;
      text-align: left;
      color: var(--text-soft);
      font-size: 0.92rem;
    }
    .palette-item[data-active="true"],
    .palette-item:hover { background: var(--accent-soft); color: var(--text); }
    .palette-item-icon {
      width: 24px; height: 24px;
      display: grid; place-items: center;
      font-family: var(--mono);
      font-weight: 700;
      color: var(--accent-strong);
      background: var(--surface-sunk);
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
      gap: 10px;
      padding: 14px 0;
    }
    .skeleton {
      background: linear-gradient(90deg,
        var(--surface-sunk) 0%,
        var(--surface-hover) 40%,
        var(--surface-sunk) 80%);
      background-size: 200% 100%;
      animation: skeleton-shimmer 1.4s ease-in-out infinite;
      border-radius: 8px;
    }
    .skeleton-line { height: 10px; }
    .skeleton-block { height: 64px; }
    .skeleton-avatar { width: 30px; height: 30px; border-radius: 10px; }

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
      .drawer-close { display: grid; place-items: center; }
      .drawer[data-open="true"] { pointer-events: auto; }
      .drawer[data-open="true"] .drawer-backdrop { opacity: 1; pointer-events: auto; }
      .drawer[data-open="true"] .drawer-panel { transform: translateX(0); }
      #menu-button { display: grid; }
      .chat-stream { padding: 10px 10px 92px; }
      .stage-inner { gap: 9px; }
      .topbar { padding: 8px 9px; }
      .composer-dock { padding-left: 8px; padding-right: 8px; }
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
    const STORAGE = {
      session: "miwhisper-companion.selectedSession",
      workspace: "miwhisper-companion.selectedWorkspace",
      draftPrefix: "miwhisper-companion.draft:",
      pinnedSessions: "miwhisper-companion.pinnedSessions",
      archivedSessions: "miwhisper-companion.archivedSessions",
      retryQueue: "miwhisper-companion.retryQueue",
      theme: "miwhisper-companion.theme",
      reasoningExpanded: "miwhisper-companion.reasoningExpanded",
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
      sseController: null,
      sseActiveSessionId: null,
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
      lastActivitySeen: 0,
      unseenAssistantCount: 0,
      titleOriginal: document.title,
      deferredInstallPrompt: null,
      retryQueue: loadJSON(STORAGE.retryQueue, []),
    };

    const SLASH_COMMANDS = [
      { slug: "resume", label: "/resume", subtitle: "Resume la conversación en puntos clave", template: "Haz un resumen ejecutivo de esta conversación en 5 bullets máximo." },
      { slug: "plan", label: "/plan", subtitle: "Plan estructurado antes de implementar", template: "Antes de implementar nada, dame un plan paso a paso con los cambios que vas a hacer en qué archivos y el orden." },
      { slug: "debug", label: "/debug", subtitle: "Modo debug: investigar antes de cambiar", template: "Hay un bug. Antes de cambiar nada, investiga, explica la causa raíz y propón 2 opciones de fix con trade-offs." },
      { slug: "test", label: "/test", subtitle: "Añadir / correr tests", template: "Añade tests para los cambios recientes y asegúrate de que pasan. Muéstrame los tests y el output." },
      { slug: "review", label: "/review", subtitle: "Revisión de código", template: "Haz una revisión crítica del último patch que hiciste: busca bugs, edge cases, riesgos y mejoras de estilo." },
      { slug: "explain", label: "/explain", subtitle: "Explica un archivo o función", template: "Explícame de arriba abajo cómo funciona " },
      { slug: "commit", label: "/commit", subtitle: "Commit + mensaje", template: "Haz commit de los cambios con un mensaje claro. No hagas push." },
      { slug: "stop", label: "/stop", subtitle: "Detener la sesión actual", action: "stop" },
      { slug: "new", label: "/new", subtitle: "Nueva sesión en este workspace", action: "new" },
      { slug: "focus", label: "/focus", subtitle: "Enfocar sesión en el Mac", action: "focus" },
      { slug: "clear", label: "/clear", subtitle: "Limpiar borrador", action: "clear" },
    ];

    init().catch((err) => showFatalError(err));

    async function init() {
      grabElements();
      applyInitialTheme();
      renderConnection("ok");
      bindEvents();
      bindKeyboardShortcuts();
      bindVisibilityAndInstall();
      registerServiceWorker();
      bindVisualViewport();

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
        "drawer", "menu-button", "new-session-button", "refresh-button",
        "command-palette-button", "theme-toggle", "install-button", "footer-dot",
        "workspace-chips", "session-list", "session-title", "session-subtitle",
        "focus-button", "stop-button", "session-menu-button", "chat-stream",
        "scroll-bottom", "scroll-bottom-badge", "composer", "composer-shell",
        "composer-hint", "voice-button", "send-button", "mic-timer",
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
      const color = theme === "dark" ? "#0b1220" : "#f8fafc";
      let meta = document.querySelector('meta[name="theme-color"]:not([media])');
      if (!meta) {
        meta = document.createElement("meta");
        meta.name = "theme-color";
        document.head.appendChild(meta);
      }
      meta.content = color;
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
      window.addEventListener("online", () => renderConnection("ok", "Conectado"));
      window.addEventListener("offline", () => renderConnection("error", "Sin conexión"));
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
        if (!document.hidden) {
          resetTitle();
          state.unseenAssistantCount = 0;
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
      navigator.serviceWorker.register("/sw.js").catch(() => {});
    }

    function openDrawer(open) {
      state.drawerOpen = open;
      els.drawer.dataset.open = open ? "true" : "false";
      els.drawer.setAttribute("aria-hidden", open ? "false" : "true");
    }

    async function refreshAll({ initial = false } = {}) {
      try {
        const ws = await api("/api/workspaces");
        state.workspaces = ws;
        if (!state.selectedWorkspaceId && state.workspaces.length) {
          state.selectedWorkspaceId = (state.workspaces.find((w) => w.isDefault) || state.workspaces[0])?.id;
        }
        if (state.selectedWorkspaceId && !state.workspaces.some((w) => w.id === state.selectedWorkspaceId)) {
          state.selectedWorkspaceId = (state.workspaces.find((w) => w.isDefault) || state.workspaces[0])?.id || null;
        }
        const ss = await api(sessionsEndpoint());
        state.sessions = ss;
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
      els.footerDot.dataset.state = stateName === "error" ? "offline" : (stateName === "warn" ? "degraded" : "");
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
              ${s.isBusy ? `<span class="session-item-busy" title="Trabajando"></span>` : ""}
            </div>
            <div class="session-item-subtitle">${escapeHTML(wsName)} · ${timeShort(new Date(s.updatedAt))}</div>
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
        json: { threadID: session.threadID },
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
        els.sessionTitle.textContent = "Nuevo chat";
        els.sessionTitle.title = "";
        els.sessionSubtitle.textContent = "";
        els.focusButton.hidden = true;
        els.stopButton.hidden = true;
        els.sessionMenuButton.hidden = true;
        document.title = state.titleOriginal;
        els.chatStream.setAttribute("aria-busy", "false");
        return;
      }
      els.sessionTitle.textContent = session.title || "Sin título";
      els.sessionTitle.title = session.title || "";
      const ws = state.workspaces.find((w) => w.id === session.workspaceID)?.name || session.workspaceName || "";
      els.sessionSubtitle.textContent = `${ws} · ${session.workingDirectory}`;
      els.focusButton.hidden = !session.hasLocalSession;
      els.stopButton.hidden = !session.isBusy;
      els.sessionMenuButton.hidden = false;
      els.chatStream.setAttribute("aria-busy", session.isBusy ? "true" : "false");
      updateDocumentTitle(session);
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
        renderStageError(state.stageError);
        return;
      }
      if (!detail) {
        renderEmptyStage();
        return;
      }
      els.chatStream.innerHTML = "";
      const inner = document.createElement("div");
      inner.className = "stage-inner";
      els.chatStream.appendChild(inner);

      const entries = ensureFinalActivity(detail.activity || [], detail.session?.latestResponse || "");
      const segments = buildSegments(entries);
      for (const seg of segments) {
        const node = renderSegment(seg);
        if (node) inner.appendChild(node);
      }

      // Optimistic bubbles awaiting send
      for (const opt of state.retryQueue.filter((r) => r.sessionID === state.selectedSessionId)) {
        inner.appendChild(renderRetryBubble(opt));
      }

      if (detail.session?.isBusy) {
        inner.appendChild(renderThinking(detail));
      }

      if (state.pinnedToBottom) requestAnimationFrame(() => scrollToBottom("auto"));
      updateScrollBottomButton();
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
        <h2>¿Qué hacemos hoy?</h2>
        <p>Dicta con el botón del micro o escribe aquí abajo. Puedes seleccionar un workspace en la barra lateral o crear una sesión nueva en el mismo directorio.</p>
        <div class="suggestion-grid">
          <button class="suggestion-card" data-prompt="Resume los cambios recientes en este workspace y dime en qué debería enfocarme ahora.">
            <strong>Resumen</strong>
            <span>Pon al día sobre lo que pasó recientemente.</span>
          </button>
          <button class="suggestion-card" data-prompt="Revisa los TODOs y bugs pendientes y dame un plan para esta semana.">
            <strong>Plan semanal</strong>
            <span>Prioriza tareas y pasos siguientes.</span>
          </button>
          <button class="suggestion-card" data-prompt="Explícame la arquitectura principal del proyecto con un diagrama de texto y puntos clave.">
            <strong>Arquitectura</strong>
            <span>Mapa mental de alto nivel.</span>
          </button>
          <button class="suggestion-card" data-prompt="Busca código que huela mal, dame un ranking de refactors por ROI y riesgo.">
            <strong>Refactors</strong>
            <span>ROI/riesgo priorizados.</span>
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

    function buildSegments(entries) {
      const out = [];
      let currentBlock = null;
      for (const entry of normalizeActivityEntries(entries)) {
        if (entry.kind === "user") {
          if (currentBlock) { out.push(currentBlock); currentBlock = null; }
          out.push({ type: "user", entry });
          continue;
        }
        const groupID = entry.groupID || `orphan-${entry.id}`;
        if (!currentBlock || currentBlock.groupID !== groupID) {
          if (currentBlock) out.push(currentBlock);
          currentBlock = { type: "assistant", groupID, entries: [] };
        }
        currentBlock.entries.push(entry);
      }
      if (currentBlock) out.push(currentBlock);
      return out;
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

    function renderSegment(seg) {
      if (seg.type === "user") return renderUserMessage(seg.entry);
      if (seg.type === "assistant") return renderAssistantBlock(seg);
      return null;
    }

    function renderUserMessage(entry) {
      const wrap = document.createElement("div");
      wrap.className = "segment segment-user";
      wrap.dataset.entryId = entry.id;
      const text = entry.detail || entry.title || "";
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
      wrap.innerHTML = `
        <div class="user-bubble">${escapeHTML(item.prompt)}</div>
        <div class="message-meta">
          ${item.status === "failed"
            ? `<span>Error al enviar</span><button type="button" data-retry="${item.id}">Reintentar</button><button type="button" data-discard="${item.id}">Descartar</button>`
            : `<span>Enviando…</span>`}
        </div>
      `;
      wrap.querySelector("[data-retry]")?.addEventListener("click", () => retryPending(item.id));
      wrap.querySelector("[data-discard]")?.addEventListener("click", () => dropPending(item.id));
      return wrap;
    }

    function renderAssistantBlock(seg) {
      const wrap = document.createElement("div");
      wrap.className = "segment segment-assistant";
      const entries = normalizeActivityEntries(seg.entries);
      if (!entries.length) return null;
      const primary = pickPrimaryEntry(entries);
      const primaryKind = primary.blockKind || primary.kind || "final";
      const kindChipClass = `kind-chip kind-${primaryKind}`;
      const title = displayTitleForEntry(primary);
      const block = document.createElement("div");
      block.className = `assistant-block is-${primaryKind}`;
      block.innerHTML = `
        <div class="assistant-block-header">
          <img class="assistant-avatar" src="/app-icon.png" alt="" aria-hidden="true">
          <strong class="assistant-title">${escapeHTML(title)}</strong>
          <span class="${kindChipClass}">${escapeHTML(blockKindLabel(primaryKind))}</span>
          ${primary.createdAt ? `<span>${timeShort(new Date(primary.createdAt))}</span>` : ""}
        </div>
      `;

      const body = document.createElement("div");
      body.className = "assistant-body";

      const reasoningEntries = entries.filter((e) => e.blockKind === "reasoning");
      if (reasoningEntries.length) {
        const details = document.createElement("details");
        details.className = "reasoning";
        const id = `reason-${seg.groupID}`;
        if (state.expandedReasoning.has(id)) details.open = true;
        details.addEventListener("toggle", () => {
          if (details.open) state.expandedReasoning.add(id);
          else state.expandedReasoning.delete(id);
          saveJSON(STORAGE.reasoningExpanded, [...state.expandedReasoning]);
        });
        const summary = document.createElement("summary");
        summary.textContent = reasoningSummaryLabel(reasoningEntries);
        details.appendChild(summary);
        const reasoningBody = document.createElement("div");
        reasoningBody.className = "reasoning-body";
        for (const e of reasoningEntries) {
          const part = document.createElement("div");
          part.style.margin = "4px 0";
          part.innerHTML = renderEntryDetail(e);
          reasoningBody.appendChild(part);
        }
        details.appendChild(reasoningBody);
        body.appendChild(details);
      }

      const visibleNonReasoning = entries.filter((e) => e.blockKind !== "reasoning" && !isRoutineSystemEntry(e));
      for (const e of visibleNonReasoning) {
        if (e.blockKind === "reasoning") continue;
        const part = document.createElement("div");
        part.innerHTML = renderEntryDetail(e);
        body.appendChild(part);
      }

      block.appendChild(body);

      const files = uniqueFiles(entries);
      if (files.length) {
        const list = document.createElement("div");
        list.className = "related-files";
        for (const f of files) {
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
        block.appendChild(list);
      }

      wrap.appendChild(block);
      return wrap;
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
      return `Pensamiento visible (${entries.length}${suffix})`;
    }

    function renderEntryDetail(entry) {
      const style = entry.detailStyle || "body";
      if (entry.blockKind === "command" || entry.command) {
        return renderCommandEntry(entry);
      }
      if (entry.blockKind === "patch" || looksLikeDiff(entry.detail)) {
        return renderPatchEntry(entry);
      }
      if (entry.blockKind === "tool") {
        return renderToolEntry(entry);
      }
      if (entry.blockKind === "final") {
        return renderMarkdown(entry.detail || "");
      }
      if (entry.blockKind === "reasoning") {
        return renderMarkdown(compactText(entry.detail || "", 4_800, 3_200, 1_100));
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
          maxCharacters: 7_000
        }));
      }
      if (!cmd && !parsed.output && entry.detail) {
        parts.push(renderCollapsibleCode("Detalle del comando", entry.detail, { open: false, maxCharacters: 5_000 }));
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
      return `<details class="activity-collapsible"${open ? " open" : ""}><summary>Diff y cambios · ${lineCount(text)} líneas</summary><div class="activity-collapsible-body">${looksLikeDiff(text) ? renderDiff(compactText(text, 9_000, 5_000, 2_500)) : renderMarkdown(text)}</div></details>`;
    }

    function renderToolEntry(entry) {
      const detail = (entry.detail || "").trim();
      if (!detail) return "";
      const lines = detail.split("\n");
      const first = lines.shift() || entry.title || "Herramienta";
      const rest = lines.join("\n").trim();
      const parts = [`<div class="activity-summary-row">${escapeHTML(compactText(first, 260, 180, 60))}</div>`];
      if (rest) {
        parts.push(renderCollapsibleCode(`Resultado · ${lineCount(rest)} líneas`, rest, { open: false, maxCharacters: 5_500 }));
      }
      return parts.join("");
    }

    function renderCollapsibleCode(summary, text, options = {}) {
      const raw = text || "";
      const maxCharacters = options.maxCharacters || 6_000;
      const compact = compactText(raw, maxCharacters, Math.floor(maxCharacters * 0.58), Math.floor(maxCharacters * 0.24));
      const omitted = compact !== raw ? `<div class="activity-hidden-note">Salida recortada para no saturar el chat. Abre la sesión completa si necesitas todo el log.</div>` : "";
      return `<details class="activity-collapsible"${options.open ? " open" : ""}><summary>${escapeHTML(summary)}</summary><div class="activity-collapsible-body"><div class="command-block ${escapeHTML(options.className || "")}">${escapeHTML(compact)}</div>${omitted}</div></details>`;
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
      el.innerHTML = `
        <span class="thinking-dots" aria-hidden="true"><span></span><span></span><span></span></span>
        <span>Pensando…</span>
      `;
      return el;
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
    function startSessionStream(sessionID) {
      stopSessionStream();
      if (!sessionID) return;
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
        if (errorStreak >= 3 && state.sseActiveSessionId === sessionID) {
          console.warn("[miwhisper] SSE degraded, falling back to polling");
          es.close();
          state.sseController = null;
          startPolling(sessionID);
        }
      });
      state.sseController = { close: () => es.close() };
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

    function onSessionDetailTick(detail) {
      if (!detail?.session) return;
      if (!sessionMatchesID(detail.session, state.selectedSessionId)) return;
      if (detail.session.id && detail.session.id !== state.selectedSessionId) {
        state.selectedSessionId = detail.session.id;
        localStorage.setItem(STORAGE.session, detail.session.id);
      }
      const prev = state.sessionDetail;
      state.sessionDetail = detail;
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
          const prevFinalCount = countFinalEntries(prev.activity);
          const nextFinalCount = countFinalEntries(detail.activity);
          if (nextFinalCount > prevFinalCount) {
            if (!state.pinnedToBottom || document.hidden) {
              state.unseenAssistantCount += nextFinalCount - prevFinalCount;
            }
          }
        }
        renderStage();
        updateTopbar();
        // Drain retry queue successes
        pruneRetryQueueAgainstServer(detail);
      } else if (state.sessionDetail.session.isBusy !== prev?.session.isBusy) {
        updateTopbar();
      }
    }

    function sessionDetailEqual(a, b) {
      if (!a || !b) return false;
      if (a.session.updatedAt !== b.session.updatedAt) return false;
      if (a.session.isBusy !== b.session.isBusy) return false;
      if ((a.activity || []).length !== (b.activity || []).length) return false;
      const last = (arr) => arr[arr.length - 1];
      const la = last(a.activity || []);
      const lb = last(b.activity || []);
      if (la?.id !== lb?.id) return false;
      if ((la?.detail || "").length !== (lb?.detail || "").length) return false;
      return true;
    }

    function countFinalEntries(activity) {
      return (activity || []).filter((e) => e.blockKind === "final" || e.kind === "assistant").length;
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

    async function sendComposer() {
      const raw = els.composer.value;
      const text = raw.trim();
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
      const preDraftKey = draftKeyFor(state.selectedSessionId);
      const optimisticID = "opt-" + Math.random().toString(36).slice(2);
      const optimistic = {
        id: optimisticID,
        sessionID: state.selectedSessionId,
        prompt: text,
        status: "sending",
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
          await api(`/api/sessions/${localSessionId}/messages`, { method: "POST", json: { prompt: text } });
        } else {
          const detail = await api("/api/sessions", {
            method: "POST",
            json: { prompt: text, workspaceID: state.selectedWorkspaceId, openWindow: false },
          });
          state.selectedSessionId = detail.session.id;
          localStorage.setItem(STORAGE.session, detail.session.id);
          state.sessionDetail = detail;
          await refreshAll();
          renderStage();
          startSessionStream(state.selectedSessionId);
        }
        dropPending(optimisticID);
        localStorage.removeItem(preDraftKey);
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
    }

    function startNewSession() {
      state.selectedSessionId = null;
      localStorage.removeItem(STORAGE.session);
      state.sessionDetail = null;
      renderSessions();
      renderStage();
      updateTopbar();
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
        composer.focus();
        saveDraft(state.selectedSessionId, composer.value);
        vibrate([10, 40, 10]);
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
        if (/\|/.test(line) && i + 1 < lines.length && /^\s*\|?\s*:?-+/.test(lines[i+1])) {
          const header = line.split("|").map((c) => c.trim()).filter((c, idx, arr) => !(idx === 0 && !c) && !(idx === arr.length - 1 && !c));
          i += 2;
          const rows = [];
          while (i < lines.length && /\|/.test(lines[i])) {
            rows.push(lines[i].split("|").map((c) => c.trim()).filter((c, idx, arr) => !(idx === 0 && !c) && !(idx === arr.length - 1 && !c)));
            i++;
          }
          out.push(`<table><thead><tr>${header.map((h) => `<th>${renderInline(h)}</th>`).join("")}</tr></thead><tbody>${rows.map((r) => `<tr>${r.map((c) => `<td>${renderInline(c)}</td>`).join("")}</tr>`).join("")}</tbody></table>`);
          continue;
        }
        const buf = [];
        while (i < lines.length && lines[i].trim()) { buf.push(lines[i]); i++; }
        out.push(`<p>${renderInline(buf.join("\n")).replace(/\n/g, "<br>")}</p>`);
      }
      return out.join("\n");
    }

    function renderInline(text) {
      const esc = escapeHTML(text);
      return esc
        .replace(/!\[([^\]]*)\]\(([^)]+)\)/g, (_, alt, src) => {
          if (/^https?:/.test(src) || (src.startsWith("/") && !src.startsWith("/Users/"))) return `<img class="inline-image" src="${src}" alt="${alt}">`;
          return `<img class="inline-image" src="/api/files/raw?path=${encodeURIComponent(src)}" alt="${alt}">`;
        })
        .replace(/\[([^\]]+)\]\(([^)]+)\)/g, (_, label, href) => {
          if (/^https?:\/\//.test(href)) return `<a href="${href}" target="_blank" rel="noopener">${label}</a>`;
          if (/^(?:file:\/\/)?(?:\/Users\/|~\/)/.test(href)) {
            const path = href.replace(/^file:\/\//, "");
            return `<a href="/preview?path=${encodeURIComponent(path)}" target="_blank" rel="noopener">${label}</a>`;
          }
          if (href.startsWith("/preview") || href.startsWith("/api/")) return `<a href="${href}" target="_blank" rel="noopener">${label}</a>`;
          return `<a href="/preview?path=${encodeURIComponent(href)}" target="_blank" rel="noopener">${label}</a>`;
        })
        .replace(/`([^`]+)`/g, "<code>$1</code>")
        .replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>")
        .replace(/_([^_]+)_/g, "<em>$1</em>")
        .replace(/\*([^*]+)\*/g, "<em>$1</em>");
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
    const CACHE = "miwhisper-companion-v11";
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
