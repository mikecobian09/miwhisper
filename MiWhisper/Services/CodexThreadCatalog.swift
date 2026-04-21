import Foundation

struct CodexWorkspaceDescriptor: Identifiable, Hashable {
    let id: String
    let name: String
    let path: String
    let isDefault: Bool
}

enum CodexWorkspaceSelection {
    static let selectedWorkspaceIDKey = "miwhisper.codex.selectedWorkspaceID"

    static func selectedWorkspace(
        defaultRoot: String,
        userDefaults: UserDefaults = .standard
    ) -> CodexWorkspaceDescriptor? {
        let workspaces = CodexWorkspaceCatalog.availableWorkspaces(defaultRoot: defaultRoot)
        let selectedID = userDefaults
            .string(forKey: selectedWorkspaceIDKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let selectedID,
           selectedID.isEmpty == false,
           let workspace = workspaces.first(where: { $0.id == selectedID }) {
            return workspace
        }

        return workspaces.first(where: \.isDefault) ?? workspaces.first
    }
}

enum CodexWorkspaceCatalog {
    static func availableWorkspaces(defaultRoot: String) -> [CodexWorkspaceDescriptor] {
        let defaultPath = standardizedPath(defaultRoot)
        if let cached = cachedWorkspaces(for: defaultPath) {
            return cached
        }

        let workspaces = computeAvailableWorkspaces(defaultPath: defaultPath)
        storeCachedWorkspaces(workspaces, for: defaultPath)
        return workspaces
    }

    private static let cacheLock = NSLock()
    private static var cachedDefaultRoot: String?
    private static var cachedDescriptors: [CodexWorkspaceDescriptor] = []
    private static var cachedAt: Date = .distantPast
    private static let cacheTTL: TimeInterval = 10

    private static func cachedWorkspaces(for defaultPath: String) -> [CodexWorkspaceDescriptor]? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        guard cachedDefaultRoot == defaultPath,
              Date().timeIntervalSince(cachedAt) < cacheTTL
        else {
            return nil
        }
        return cachedDescriptors
    }

    private static func storeCachedWorkspaces(_ workspaces: [CodexWorkspaceDescriptor], for defaultPath: String) {
        cacheLock.lock()
        cachedDefaultRoot = defaultPath
        cachedDescriptors = workspaces
        cachedAt = Date()
        cacheLock.unlock()
    }

    private static func computeAvailableWorkspaces(defaultPath: String) -> [CodexWorkspaceDescriptor] {
        var descriptorsByPath: [String: CodexWorkspaceDescriptor] = [:]
        descriptorsByPath[defaultPath] = CodexWorkspaceDescriptor(
            id: stableID(for: defaultPath),
            name: displayName(for: defaultPath),
            path: defaultPath,
            isDefault: true
        )

        for cwd in discoveredCodexWorkingDirectories() {
            let workspacePath = inferredWorkspaceRoot(for: cwd, defaultRoot: defaultPath)
            guard descriptorsByPath[workspacePath] == nil else { continue }

            descriptorsByPath[workspacePath] = CodexWorkspaceDescriptor(
                id: stableID(for: workspacePath),
                name: displayName(for: workspacePath),
                path: workspacePath,
                isDefault: false
            )
        }

        return descriptorsByPath.values.sorted { lhs, rhs in
            if lhs.isDefault != rhs.isDefault {
                return lhs.isDefault
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private static func discoveredCodexWorkingDirectories() -> [String] {
        var ordered: [String] = []
        var seen: Set<String> = []

        for cwd in CodexStateDatabase.loadWorkspaceCWDs() {
            let path = standardizedPath(cwd)
            guard seen.insert(path).inserted else { continue }
            ordered.append(path)
        }

        if ordered.isEmpty == false {
            return ordered
        }

        let sessionsRootURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/sessions")
        guard let enumerator = FileManager.default.enumerator(
            at: sessionsRootURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return ordered
        }

        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "jsonl",
                  let cwd = sessionWorkingDirectory(at: fileURL)
            else {
                continue
            }

            let path = standardizedPath(cwd)
            guard seen.insert(path).inserted else { continue }
            ordered.append(path)
        }

        return ordered
    }

    private static func sessionWorkingDirectory(at fileURL: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            return nil
        }
        defer { try? handle.close() }

        guard let data = try? handle.read(upToCount: 4096),
              let contents = String(data: data, encoding: .utf8),
              let firstLine = contents.split(whereSeparator: \.isNewline).first,
              let jsonData = String(firstLine).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let payload = object["payload"] as? [String: Any],
              let cwd = payload["cwd"] as? String,
              cwd.isEmpty == false
        else {
            return nil
        }

        return cwd
    }

    private static func inferredWorkspaceRoot(for cwd: String, defaultRoot: String) -> String {
        let standardizedCWD = standardizedPath(cwd)
        if standardizedCWD == defaultRoot || standardizedCWD.hasPrefix(defaultRoot + "/") {
            return defaultRoot
        }

        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: standardizedCWD, isDirectory: &isDirectory), isDirectory.boolValue else {
            return standardizedCWD
        }

        var current = URL(fileURLWithPath: standardizedCWD).standardizedFileURL
        let homePath = standardizedPath(NSHomeDirectory())

        while current.path.hasPrefix(homePath) {
            if containsWorkspaceMarker(at: current) {
                return current.path
            }

            let parent = current.deletingLastPathComponent()
            if parent.path == current.path {
                break
            }
            current = parent
        }

        return standardizedCWD
    }

    private static func containsWorkspaceMarker(at url: URL) -> Bool {
        let fileManager = FileManager.default
        let markerNames = [
            ".git",
            "AGENTS.md",
            "package.json",
            "Package.swift",
            "pyproject.toml",
            "Cargo.toml",
            "go.mod",
            "README.md"
        ]

        if markerNames.contains(where: { fileManager.fileExists(atPath: url.appendingPathComponent($0).path) }) {
            return true
        }

        return false
    }

    private static func displayName(for path: String) -> String {
        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent
        return name.isEmpty ? path : name
    }

    private static func stableID(for path: String) -> String {
        let safe = path
            .lowercased()
            .replacingOccurrences(of: NSHomeDirectory().lowercased(), with: "~")
            .map { character -> Character in
                character.isLetter || character.isNumber ? character : "-"
            }
        let collapsed = String(safe).split(separator: "-").joined(separator: "-")
        return collapsed.isEmpty ? "workspace" : collapsed
    }

    private static func standardizedPath(_ path: String) -> String {
        URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
            .standardizedFileURL
            .path
    }
}

private enum CodexStateDatabase {
    private struct WorkspaceRow: Decodable {
        let cwd: String?
    }

    struct ThreadRow: Decodable {
        let id: String?
        let title: String?
        let updatedAtSeconds: Int?
        let updatedAtMilliseconds: Int?
        let cwd: String?

        private enum CodingKeys: String, CodingKey {
            case id
            case title
            case updatedAtSeconds = "updated_at"
            case updatedAtMilliseconds = "updated_at_ms"
            case cwd
        }
    }

    private static let databaseURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/state_5.sqlite")
    private static let cacheLock = NSLock()
    private static var cachedThreads: [ThreadRow] = []
    private static var cachedThreadsAt: Date = .distantPast
    private static let cacheTTL: TimeInterval = 5

    static func loadWorkspaceCWDs() -> [String] {
        var latestByCWD: [String: Date] = [:]
        for row in loadThreads() {
            guard let cwd = row.cwd, cwd.isEmpty == false else { continue }
            let updatedAt = row.updatedAt
            if latestByCWD[cwd].map({ updatedAt > $0 }) ?? true {
                latestByCWD[cwd] = updatedAt
            }
        }

        return latestByCWD
            .sorted { lhs, rhs in lhs.value > rhs.value }
            .map(\.key)
    }

    static func loadThreads() -> [ThreadRow] {
        if let cached = cachedThreadRows() {
            return cached
        }

        let sql = """
        select id, title, updated_at, updated_at_ms, cwd
        from threads
        where id is not null and id != '' and coalesce(archived, 0) = 0
        order by coalesce(updated_at_ms, updated_at * 1000) desc;
        """
        let rows = (try? query(sql, as: [ThreadRow].self)) ?? []
        storeCachedThreadRows(rows)
        return rows
    }

    private static func cachedThreadRows() -> [ThreadRow]? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        guard Date().timeIntervalSince(cachedThreadsAt) < cacheTTL else {
            return nil
        }
        return cachedThreads
    }

    private static func storeCachedThreadRows(_ rows: [ThreadRow]) {
        cacheLock.lock()
        cachedThreads = rows
        cachedThreadsAt = Date()
        cacheLock.unlock()
    }

    private static func query<T: Decodable>(_ sql: String, as type: T.Type) throws -> T {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-json", databaseURL.path, sql]

        let output = Pipe()
        let errorOutput = Pipe()
        process.standardOutput = output
        process.standardError = errorOutput

        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        _ = errorOutput.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            throw NSError(domain: "CodexStateDatabase", code: Int(process.terminationStatus))
        }

        return try JSONDecoder().decode(T.self, from: data)
    }
}

private extension CodexStateDatabase.ThreadRow {
    var updatedAt: Date {
        updatedAtMilliseconds
            .map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) }
            ?? updatedAtSeconds.map { Date(timeIntervalSince1970: TimeInterval($0)) }
            ?? .distantPast
    }
}

struct CodexThreadListEntry: Identifiable {
    let id: String
    let recordID: UUID?
    let threadID: String?
    let title: String
    let workingDirectory: String
    let workspaceName: String
    let updatedAt: Date
    let createdAt: Date?
    let isBusy: Bool
    let latestResponse: String
}

@MainActor
final class CodexThreadCatalog: ObservableObject {
    static let shared = CodexThreadCatalog()

    @Published private(set) var entries: [CodexThreadListEntry] = []

    private struct ThreadIndexItem {
        let threadID: String
        let threadName: String
        let updatedAt: Date
        let workingDirectory: String?
    }

    private struct ThreadContext {
        let workingDirectory: String
        let workspaceName: String
    }

    private let indexURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/session_index.jsonl")
    private let sessionsRootURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/sessions")
    private var cachedContextsByThreadID: [String: ThreadContext] = [:]

    func reload(workspaces: [CodexWorkspaceDescriptor]) {
        let indexItems = loadIndexItems()
        let indexByThreadID = Dictionary(uniqueKeysWithValues: indexItems.map { ($0.threadID, $0) })
        for item in indexItems {
            guard let cwd = item.workingDirectory, cachedContextsByThreadID[item.threadID] == nil else {
                continue
            }

            cachedContextsByThreadID[item.threadID] = ThreadContext(
                workingDirectory: cwd,
                workspaceName: workspaceName(for: cwd, workspaces: workspaces)
                    ?? URL(fileURLWithPath: cwd).lastPathComponent
            )
        }
        loadMissingThreadContexts(for: indexItems.map(\.threadID), workspaces: workspaces)
        synchronizeLocalSessionTitles(with: indexByThreadID)

        let localRecords = CodexSessionManager.shared.allSessionRecords()
        var entriesByKey: [String: CodexThreadListEntry] = [:]
        var recordByThreadID: [String: CodexSessionRecord] = [:]

        for record in localRecords.sorted(by: { $0.updatedAt > $1.updatedAt }) {
            if let threadID = record.threadID, recordByThreadID[threadID] == nil {
                recordByThreadID[threadID] = record
            }
        }

        for record in localRecords {
            let matchedIndex = record.threadID.flatMap { indexByThreadID[$0] }
            let matchedContext = record.threadID.flatMap { cachedContextsByThreadID[$0] }
            let workspaceName = workspaceName(for: record.workingDirectory, workspaces: workspaces)
                ?? matchedContext?.workspaceName
                ?? URL(fileURLWithPath: record.workingDirectory).lastPathComponent
            let title = matchedIndex?.threadName ?? record.title
            let key = record.threadID ?? "record-\(record.id.uuidString)"
            let updatedAt = max(record.updatedAt, matchedIndex?.updatedAt ?? .distantPast)

            entriesByKey[key] = CodexThreadListEntry(
                id: key,
                recordID: record.id,
                threadID: record.threadID,
                title: title,
                workingDirectory: record.workingDirectory,
                workspaceName: workspaceName,
                updatedAt: updatedAt,
                createdAt: record.createdAt,
                isBusy: record.isBusy ?? false,
                latestResponse: record.latestResponse
            )
        }

        for item in indexItems {
            guard recordByThreadID[item.threadID] == nil else { continue }
            guard let context = cachedContextsByThreadID[item.threadID] else { continue }

            entriesByKey[item.threadID] = CodexThreadListEntry(
                id: item.threadID,
                recordID: nil,
                threadID: item.threadID,
                title: item.threadName,
                workingDirectory: context.workingDirectory,
                workspaceName: context.workspaceName,
                updatedAt: item.updatedAt,
                createdAt: nil,
                isBusy: false,
                latestResponse: ""
            )
        }

        entries = entriesByKey.values.sorted { lhs, rhs in
            if lhs.updatedAt == rhs.updatedAt {
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    private func loadIndexItems() -> [ThreadIndexItem] {
        let sqliteItems = CodexStateDatabase.loadThreads().compactMap { row -> ThreadIndexItem? in
            guard let threadID = row.id, threadID.isEmpty == false else {
                return nil
            }

            let title = row.title?.trimmingCharacters(in: .whitespacesAndNewlines)

            return ThreadIndexItem(
                threadID: threadID,
                threadName: title?.isEmpty == false ? title! : "Codex Thread",
                updatedAt: row.updatedAt,
                workingDirectory: row.cwd
            )
        }

        if sqliteItems.isEmpty == false {
            return sqliteItems
        }

        guard let data = try? Data(contentsOf: indexURL),
              let contents = String(data: data, encoding: .utf8)
        else {
            return []
        }

        return contents
            .split(whereSeparator: \.isNewline)
            .compactMap { parseIndexLine(String($0)) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private func parseIndexLine(_ line: String) -> ThreadIndexItem? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let threadID = object["id"] as? String,
              let threadName = object["thread_name"] as? String,
              let updatedAtString = object["updated_at"] as? String,
              let updatedAt = Self.parseDate(updatedAtString)
        else {
            return nil
        }

        return ThreadIndexItem(threadID: threadID, threadName: threadName, updatedAt: updatedAt, workingDirectory: nil)
    }

    private func loadMissingThreadContexts(for threadIDs: [String], workspaces: [CodexWorkspaceDescriptor]) {
        let missingIDs = Set(threadIDs.filter { cachedContextsByThreadID[$0] == nil })
        guard !missingIDs.isEmpty else { return }

        guard let enumerator = FileManager.default.enumerator(
            at: sessionsRootURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        var unresolved = missingIDs
        for case let fileURL as URL in enumerator {
            guard unresolved.isEmpty == false else { break }
            guard fileURL.pathExtension == "jsonl" else { continue }

            guard let context = parseSessionMetaContext(at: fileURL, workspaces: workspaces) else {
                continue
            }

            let threadID = context.0
            guard unresolved.contains(threadID) else { continue }

            cachedContextsByThreadID[threadID] = context.1
            unresolved.remove(threadID)
        }
    }

    private func parseSessionMetaContext(
        at fileURL: URL,
        workspaces: [CodexWorkspaceDescriptor]
    ) -> (String, ThreadContext)? {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            return nil
        }
        defer { try? handle.close() }

        guard let data = try? handle.read(upToCount: 4096),
              let contents = String(data: data, encoding: .utf8),
              let firstLine = contents.split(whereSeparator: \.isNewline).first,
              let jsonData = String(firstLine).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let payload = object["payload"] as? [String: Any],
              let threadID = payload["id"] as? String,
              let cwd = payload["cwd"] as? String
        else {
            return nil
        }

        guard let workspace = workspaces.first(where: { cwd == $0.path || cwd.hasPrefix($0.path + "/") }) else {
            return nil
        }

        return (
            threadID,
            ThreadContext(
                workingDirectory: cwd,
                workspaceName: workspace.name
            )
        )
    }

    private func synchronizeLocalSessionTitles(with indexByThreadID: [String: ThreadIndexItem]) {
        for record in CodexSessionManager.shared.allSessionRecords() {
            guard let threadID = record.threadID,
                  let indexItem = indexByThreadID[threadID],
                  record.title != indexItem.threadName
            else {
                continue
            }

            CodexSessionStore.shared.updateSession(id: record.id) { session in
                session.title = indexItem.threadName
            }
        }
    }

    private func workspaceName(
        for workingDirectory: String,
        workspaces: [CodexWorkspaceDescriptor]
    ) -> String? {
        workspaces.first(where: { workingDirectory == $0.path || workingDirectory.hasPrefix($0.path + "/") })?.name
    }

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let basicISO8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static func parseDate(_ value: String) -> Date? {
        iso8601Formatter.date(from: value) ?? basicISO8601Formatter.date(from: value)
    }
}
