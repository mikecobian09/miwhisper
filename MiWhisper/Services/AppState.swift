import AppKit
import AVFoundation
import ApplicationServices
import Combine
import Foundation
import ServiceManagement

struct TranscriptEntry: Codable, Identifiable {
    let id: UUID
    let text: String
    let createdAt: Date
}

struct UsageDayBucket: Codable, Identifiable {
    let dayStart: Date
    var dictationCount: Int
    var codexPromptCount: Int
    var literalCount: Int
    var translationCount: Int
    var wordCount: Int
    var characterCount: Int
    var audioSeconds: Double
    var estimatedTypingSeconds: Double

    var id: Date { dayStart }

    var totalUses: Int {
        dictationCount + codexPromptCount
    }

    var estimatedSavedSeconds: Double {
        max(estimatedTypingSeconds - audioSeconds, 0)
    }

    mutating func record(
        intent: HotkeyIntent,
        mode: TranscriptionMode,
        wordCount: Int,
        characterCount: Int,
        audioSeconds: Double,
        estimatedTypingSeconds: Double
    ) {
        switch intent {
        case .dictation:
            dictationCount += 1
        case .codexPrompt:
            codexPromptCount += 1
        }

        switch mode {
        case .literal:
            literalCount += 1
        case .translateToEnglish:
            translationCount += 1
        }

        self.wordCount += wordCount
        self.characterCount += characterCount
        self.audioSeconds += audioSeconds
        self.estimatedTypingSeconds += estimatedTypingSeconds
    }
}

enum UsageStatsPeriod: String, CaseIterable, Identifiable {
    case day
    case week
    case month
    case year
    case allTime

    var id: String { rawValue }

    var title: String {
        switch self {
        case .day:
            return "Day"
        case .week:
            return "Week"
        case .month:
            return "Month"
        case .year:
            return "Year"
        case .allTime:
            return "All"
        }
    }
}

struct UsageStatsSnapshot {
    let dictationCount: Int
    let codexPromptCount: Int
    let literalCount: Int
    let translationCount: Int
    let wordCount: Int
    let characterCount: Int
    let audioSeconds: Double
    let estimatedTypingSeconds: Double

    static let empty = UsageStatsSnapshot(
        dictationCount: 0,
        codexPromptCount: 0,
        literalCount: 0,
        translationCount: 0,
        wordCount: 0,
        characterCount: 0,
        audioSeconds: 0,
        estimatedTypingSeconds: 0
    )

    var totalUses: Int {
        dictationCount + codexPromptCount
    }

    var estimatedSavedSeconds: Double {
        max(estimatedTypingSeconds - audioSeconds, 0)
    }
}

struct UsageChartPoint: Identifiable {
    let dayStart: Date
    let uses: Int
    let savedMinutes: Double

    var id: Date { dayStart }
}

enum TranscriptionMode: String, CaseIterable, Identifiable {
    case literal
    case translateToEnglish

    var id: String { rawValue }

    var title: String {
        switch self {
        case .literal:
            return "Literal"
        case .translateToEnglish:
            return "Translate to English"
        }
    }

    var detail: String {
        switch self {
        case .literal:
            return "Input and output stay in the same spoken language"
        case .translateToEnglish:
            return "Whatever you say, the output is always English"
        }
    }
}

enum CodexReasoningEffort: String, CaseIterable, Identifiable, Codable {
    case useConfigDefault
    case low
    case medium
    case high
    case intense

    var id: String { rawValue }

    var title: String {
        switch self {
        case .useConfigDefault:
            return "Default"
        case .low:
            return "Low"
        case .medium:
            return "Medium"
        case .high:
            return "High"
        case .intense:
            return "Extreme"
        }
    }

    var cliValue: String? {
        switch self {
        case .useConfigDefault:
            return nil
        case .low:
            return "low"
        case .medium:
            return "medium"
        case .high:
            return "high"
        case .intense:
            return "xhigh"
        }
    }
}

enum CodexServiceTier: String, CaseIterable, Identifiable, Codable {
    case useConfigDefault
    case fast
    case flex

    var id: String { rawValue }

    var title: String {
        switch self {
        case .useConfigDefault:
            return "Default"
        case .fast:
            return "Fast"
        case .flex:
            return "Flex"
        }
    }

    var appServerValue: String? {
        switch self {
        case .useConfigDefault:
            return nil
        case .fast:
            return "fast"
        case .flex:
            return "flex"
        }
    }

    static func fromStoredRawValue(_ rawValue: String) -> CodexServiceTier {
        switch rawValue {
        case Self.useConfigDefault.rawValue, "standard":
            return .useConfigDefault
        case Self.fast.rawValue:
            return .fast
        case Self.flex.rawValue, "priority":
            return .flex
        default:
            return .useConfigDefault
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self = Self.fromStoredRawValue(try container.decode(String.self))
    }
}

struct CodexModelOption: Identifiable, Hashable {
    let id: String
    let title: String

    init(id: String, title: String? = nil) {
        self.id = id
        self.title = title ?? id
    }
}

struct WhisperModelPreset: Identifiable, Equatable {
    let id: String
    let title: String
    let filename: String
    let detail: String
    let sizeDescription: String
    let approximateBytes: Int64

    var downloadURL: URL {
        URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(filename)")!
    }
}

struct TextContinuationFormatter {
    struct Context {
        let precedingCharacter: Character?
        let hasSelection: Bool
    }

    func format(_ transcript: String, context: Context) -> String {
        var text = normalizeWhitespace(in: transcript)
        guard !text.isEmpty else { return text }

        if let dictationCommand = standaloneDictationCommand(for: text) {
            text = dictationCommand
        } else if isLikelyEmail(text) {
            text = formatEmail(text)
        } else if isLikelyURL(text) {
            text = formatURL(text)
        } else if isLikelyPhoneNumber(text) {
            text = formatPhoneNumber(text)
        }

        return applyContinuationRules(to: text, context: context)
    }

    private func normalizeWhitespace(in text: String) -> String {
        text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func standaloneDictationCommand(for text: String) -> String? {
        let normalized = commandLookupKey(for: text)
        let commands: [String: String] = [
            "coma": ",",
            "comma": ",",
            "punto": ".",
            "period": ".",
            "dot": ".",
            "dos puntos": ":",
            "colon": ":",
            "punto y coma": ";",
            "semicolon": ";",
            "abre parentesis": "(",
            "cierra parentesis": ")",
            "abre corchete": "[",
            "cierra corchete": "]",
            "abre llave": "{",
            "cierra llave": "}",
            "interrogacion": "?",
            "exclamacion": "!",
            "nueva linea": "\n",
            "salto de linea": "\n",
        ]
        return commands[normalized]
    }

    private func isLikelyEmail(_ text: String) -> Bool {
        let tokens = normalizedTokens(from: text)
        guard !tokens.isEmpty, tokens.count <= 14 else { return false }
        return tokens.contains("arroba") || text.contains("@")
    }

    private func formatEmail(_ text: String) -> String {
        var candidate = " " + text.lowercased() + " "
        let replacements = [
            (" guion bajo ", "_"),
            (" underscore ", "_"),
            (" subrayado ", "_"),
            (" arroba ", "@"),
            (" at sign ", "@"),
            (" at ", "@"),
            (" punto ", "."),
            (" dot ", "."),
            (" guion ", "-"),
            (" dash ", "-"),
            (" menos ", "-"),
            (" mas ", "+"),
            (" más ", "+"),
        ]

        for (pattern, replacement) in replacements {
            candidate = candidate.replacingOccurrences(of: pattern, with: replacement)
        }

        candidate = replacingDigitWords(in: candidate)
        return candidate.replacingOccurrences(of: " ", with: "")
    }

    private func isLikelyURL(_ text: String) -> Bool {
        let lowered = commandLookupKey(for: text)
        let tokens = normalizedTokens(from: lowered)
        guard !tokens.isEmpty, tokens.count <= 18 else { return false }

        let hasURLMarker =
            tokens.contains("www") ||
            tokens.contains("http") ||
            tokens.contains("https") ||
            tokens.contains("slash") ||
            tokens.contains("barra")

        let hasDomainHint =
            tokens.contains("punto") ||
            tokens.contains("dot") ||
            tokens.contains(where: { ["com", "es", "org", "net", "io", "dev", "app"].contains($0) })

        let bareDomainCandidate =
            tokens.count <= 8 &&
            tokens.contains("punto") &&
            tokens.contains(where: { ["com", "es", "org", "net", "io", "dev", "app"].contains($0) })

        return (hasURLMarker && hasDomainHint) || bareDomainCandidate
    }

    private func formatURL(_ text: String) -> String {
        var candidate = " " + text.lowercased() + " "
        let replacements = [
            (" dos puntos ", ":"),
            (" colon ", ":"),
            (" punto ", "."),
            (" dot ", "."),
            (" barra ", "/"),
            (" slash ", "/"),
            (" guion bajo ", "_"),
            (" underscore ", "_"),
            (" guion ", "-"),
            (" dash ", "-"),
        ]

        for (pattern, replacement) in replacements {
            candidate = candidate.replacingOccurrences(of: pattern, with: replacement)
        }

        candidate = replacingDigitWords(in: candidate)
        candidate = candidate.replacingOccurrences(of: " ", with: "")
        candidate = candidate.replacingOccurrences(of: "https//", with: "https://")
        candidate = candidate.replacingOccurrences(of: "http//", with: "http://")
        return candidate
    }

    private func isLikelyPhoneNumber(_ text: String) -> Bool {
        let tokens = normalizedTokens(from: text)
        guard !tokens.isEmpty, tokens.count <= 20 else { return false }

        let recognized = tokens.filter { phoneTokenValue(for: $0) != nil }
        let digitCount = recognized.reduce(0) { partialResult, token in
            partialResult + countDigits(in: phoneTokenValue(for: token) ?? "")
        }

        return digitCount >= 7 && recognized.count * 2 >= tokens.count
    }

    private func formatPhoneNumber(_ text: String) -> String {
        let tokens = normalizedTokens(from: text)
        var output = ""

        for token in tokens {
            guard let value = phoneTokenValue(for: token) else { continue }

            if value == " " {
                if let lastCharacter = output.last, lastCharacter != " ", lastCharacter != "-" {
                    output.append(" ")
                }
                continue
            }

            if value == "-" {
                if let lastCharacter = output.last, lastCharacter != " ", lastCharacter != "-", lastCharacter != "+" {
                    output.append("-")
                }
                continue
            }

            if value == "+" {
                if output.isEmpty {
                    output.append("+")
                }
                continue
            }

            output.append(value)
        }

        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func applyContinuationRules(to text: String, context: Context) -> String {
        guard !text.isEmpty else { return text }
        guard !context.hasSelection else { return text }

        var output = text

        if let precedingCharacter = context.precedingCharacter {
            if needsLeadingSpace(after: precedingCharacter, before: output.first) {
                output = " " + output
            }

            if shouldLowercaseInitial(in: output, after: precedingCharacter) {
                output = lowercasingInitialLetter(in: output)
            }
        }

        return output
    }

    private func needsLeadingSpace(after precedingCharacter: Character, before incomingCharacter: Character?) -> Bool {
        guard let incomingCharacter else { return false }

        if precedingCharacter.isWhitespace || precedingCharacter.isNewline {
            return false
        }

        if openingPunctuation.contains(precedingCharacter) {
            return false
        }

        if closingPunctuation.contains(incomingCharacter) || incomingCharacter == "'" || incomingCharacter == "\"" {
            return false
        }

        return true
    }

    private func shouldLowercaseInitial(in text: String, after precedingCharacter: Character) -> Bool {
        guard !sentenceBoundaryCharacters.contains(precedingCharacter), precedingCharacter != "\n" else {
            return false
        }

        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let firstWord = trimmed.split(whereSeparator: \.isWhitespace).first else {
            return false
        }

        let firstToken = String(firstWord)
        guard let firstScalar = firstToken.unicodeScalars.first else { return false }
        guard CharacterSet.uppercaseLetters.contains(firstScalar) else { return false }

        let remainder = firstToken.unicodeScalars.dropFirst()
        return remainder.contains(where: { CharacterSet.lowercaseLetters.contains($0) })
    }

    private func lowercasingInitialLetter(in text: String) -> String {
        guard let firstIndex = text.firstIndex(where: { !$0.isWhitespace }) else {
            return text
        }

        var output = text
        let character = String(output[firstIndex]).lowercased()
        output.replaceSubrange(firstIndex ... firstIndex, with: character)
        return output
    }

    private func commandLookupKey(for text: String) -> String {
        text
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizedTokens(from text: String) -> [String] {
        commandLookupKey(for: text)
            .split(separator: " ")
            .map(String.init)
    }

    private func replacingDigitWords(in text: String) -> String {
        var output = text
        let replacements = [
            (" cero ", " 0 "),
            (" zero ", " 0 "),
            (" uno ", " 1 "),
            (" una ", " 1 "),
            (" one ", " 1 "),
            (" dos ", " 2 "),
            (" two ", " 2 "),
            (" tres ", " 3 "),
            (" three ", " 3 "),
            (" cuatro ", " 4 "),
            (" four ", " 4 "),
            (" cinco ", " 5 "),
            (" five ", " 5 "),
            (" seis ", " 6 "),
            (" six ", " 6 "),
            (" siete ", " 7 "),
            (" seven ", " 7 "),
            (" ocho ", " 8 "),
            (" eight ", " 8 "),
            (" nueve ", " 9 "),
            (" nine ", " 9 "),
        ]

        for (pattern, replacement) in replacements {
            output = output.replacingOccurrences(of: pattern, with: replacement)
        }

        return output
    }

    private func phoneTokenValue(for token: String) -> String? {
        if token.allSatisfy(\.isNumber) {
            return token
        }

        switch token {
        case "cero", "zero":
            return "0"
        case "uno", "una", "one":
            return "1"
        case "dos", "two":
            return "2"
        case "tres", "three":
            return "3"
        case "cuatro", "four":
            return "4"
        case "cinco", "five":
            return "5"
        case "seis", "six":
            return "6"
        case "siete", "seven":
            return "7"
        case "ocho", "eight":
            return "8"
        case "nueve", "nine":
            return "9"
        case "mas", "más", "plus":
            return "+"
        case "guion", "dash", "menos":
            return "-"
        case "espacio", "space":
            return " "
        default:
            return nil
        }
    }

    private func countDigits(in text: String) -> Int {
        text.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) }.count
    }

    private let openingPunctuation: Set<Character> = ["(", "[", "{", "\"", "'", "\n"]
    private let closingPunctuation: Set<Character> = [".", ",", ";", ":", "!", "?", ")", "]", "}"]
    private let sentenceBoundaryCharacters: Set<Character> = [".", "!", "?", "\n"]
}

struct ModelDownloadState: Equatable {
    let presetID: String
    let bytesWritten: Int64
    let totalBytesExpected: Int64
    let startedAt: Date
}

private final class ModelDownloadCoordinator: NSObject, URLSessionDownloadDelegate {
    private struct Context {
        let presetID: String
        let destinationURL: URL
        let startedAt: Date
    }

    var onProgress: ((String, Int64, Int64, Date) -> Void)?
    var onCompletion: ((String, Result<Void, Error>) -> Void)?

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        return URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
    }()

    private var contextsByTaskIdentifier: [Int: Context] = [:]

    func startDownload(presetID: String, sourceURL: URL, destinationURL: URL) {
        cancelDownload()

        let task = session.downloadTask(with: sourceURL)
        contextsByTaskIdentifier[task.taskIdentifier] = Context(
            presetID: presetID,
            destinationURL: destinationURL,
            startedAt: Date()
        )
        task.resume()
    }

    func cancelDownload() {
        session.getAllTasks { tasks in
            tasks.forEach { $0.cancel() }
        }
        contextsByTaskIdentifier.removeAll()
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let context = contextsByTaskIdentifier[downloadTask.taskIdentifier] else {
            return
        }

        onProgress?(
            context.presetID,
            totalBytesWritten,
            totalBytesExpectedToWrite,
            context.startedAt
        )
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let context = contextsByTaskIdentifier.removeValue(forKey: downloadTask.taskIdentifier) else {
            return
        }

        do {
            let fileManager = FileManager.default
            try fileManager.createDirectory(
                at: context.destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            if fileManager.fileExists(atPath: context.destinationURL.path) {
                try fileManager.removeItem(at: context.destinationURL)
            }

            try fileManager.moveItem(at: location, to: context.destinationURL)
            onCompletion?(context.presetID, .success(()))
        } catch {
            onCompletion?(context.presetID, .failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let error else {
            return
        }

        guard let context = contextsByTaskIdentifier.removeValue(forKey: task.taskIdentifier) else {
            return
        }

        onCompletion?(context.presetID, .failure(error))
    }
}

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()
    private static let transcriptHistoryKey = "transcriptHistory"
    private static let maxTranscriptHistory = 10
    private static let usageDailyBucketsKey = "usageDailyBuckets"
    private static let maxUsageDailyBuckets = 730
    private static let transcriptionModeKey = "transcriptionMode"
    private static let codexDefaultModelKey = "codexDefaultModel"
    private static let codexReasoningEffortKey = "codexDefaultReasoningEffort"
    private static let codexServiceTierKey = "codexServiceTier"
    private static let launchAtLoginPreferenceKey = "launchAtLoginPreference"
    private static let estimatedTypingWordsPerMinute = 38.0
    private struct LastInsertionState {
        let processIdentifier: pid_t
        let trailingCharacter: Character?
        let trailingContext: String
    }

    @Published var isRecording = false
    @Published var isTranscribing = false
    @Published var recordingPulse = 0
    @Published var statusMessage = "Ready"
    @Published var lastTranscript = ""
    @Published var transcriptHistory: [TranscriptEntry] = []
    @Published var usageDailyBuckets: [UsageDayBucket] = []
    @Published var errorMessage: String?
    @Published var hasMicrophoneAccess = false
    @Published var hasAccessibilityAccess = false
    @Published var hasInputMonitoringAccess = false
    @Published var hasNotificationAccess = false
    @Published var hasHotkeyMonitor = false
    @Published var modelDownloadState: ModelDownloadState?
    @Published var launchAtLoginEnabled = false
    @Published var launchAtLoginRequiresApproval = false
    @Published var launchAtLoginErrorMessage: String?

    private let defaults = UserDefaults.standard
    private let recorder = AudioRecorder()
    private let transcriber = WhisperTranscriber()
    private let paster = TextPaster()
    private let inserter = AccessibilityTextInsertion()
    private let inAppInserter = InAppTextInsertionManager.shared
    private let notifier = NotificationPresenter.shared
    private let textFormatter = TextContinuationFormatter()
    private let modelDownloader = ModelDownloadCoordinator()

    private var currentRecordingURL: URL?
    private var recordingStartedAt: Date?
    private var focusedTarget: AccessibilityTextInsertion.FocusedTarget?
    private var shouldUseInAppInsertion = false
    private var pulseTask: Task<Void, Never>?
    private var lastInsertionState: LastInsertionState?
    private var currentHotkeyIntent: HotkeyIntent = .dictation
    let workspaceRoot = AppState.detectWorkspaceRoot()

    var currentAppBundlePath: String {
        Bundle.main.bundlePath
    }

    var cliPath: String {
        get { defaults.string(forKey: "cliPath") ?? defaultCLIPath }
        set {
            objectWillChange.send()
            defaults.set(newValue, forKey: "cliPath")
        }
    }

    var modelPath: String {
        get { defaults.string(forKey: "modelPath") ?? defaultModelPath }
        set {
            objectWillChange.send()
            defaults.set(newValue, forKey: "modelPath")
        }
    }

    var codexPath: String {
        get { defaults.string(forKey: "codexPath") ?? defaultCodexPath }
        set {
            objectWillChange.send()
            defaults.set(newValue, forKey: "codexPath")
        }
    }

    var language: String {
        get { defaults.string(forKey: "language") ?? "auto" }
        set {
            objectWillChange.send()
            defaults.set(newValue, forKey: "language")
        }
    }

    var codexDefaultModel: String {
        get { defaults.string(forKey: Self.codexDefaultModelKey) ?? "" }
        set {
            objectWillChange.send()
            defaults.set(newValue, forKey: Self.codexDefaultModelKey)
        }
    }

    var codexReasoningEffort: CodexReasoningEffort {
        get {
            guard
                let rawValue = defaults.string(forKey: Self.codexReasoningEffortKey),
                let effort = CodexReasoningEffort(rawValue: rawValue)
            else {
                return .useConfigDefault
            }
            return effort
        }
        set {
            objectWillChange.send()
            defaults.set(newValue.rawValue, forKey: Self.codexReasoningEffortKey)
        }
    }

    var codexServiceTier: CodexServiceTier {
        get {
            guard let rawValue = defaults.string(forKey: Self.codexServiceTierKey) else {
                return .useConfigDefault
            }
            return CodexServiceTier.fromStoredRawValue(rawValue)
        }
        set {
            objectWillChange.send()
            defaults.set(newValue.rawValue, forKey: Self.codexServiceTierKey)
        }
    }

    var codexModelOptions: [CodexModelOption] {
        var options = [
            CodexModelOption(id: "", title: "Config default"),
            CodexModelOption(id: "gpt-5.4"),
            CodexModelOption(id: "gpt-5.4-mini"),
            CodexModelOption(id: "gpt-5.3-codex"),
            CodexModelOption(id: "gpt-5.3-codex-spark"),
            CodexModelOption(id: "gpt-5.2-codex"),
            CodexModelOption(id: "gpt-5.2"),
            CodexModelOption(id: "gpt-5.1-codex-max"),
            CodexModelOption(id: "gpt-5.1-codex-mini"),
            CodexModelOption(id: "codex-mini-latest"),
        ]

        let currentValue = codexDefaultModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !currentValue.isEmpty, !options.contains(where: { $0.id == currentValue }) {
            options.insert(CodexModelOption(id: currentValue, title: "Saved: \(currentValue)"), at: 1)
        }

        return options
    }

    var transcriptionMode: TranscriptionMode {
        get {
            guard
                let rawValue = defaults.string(forKey: Self.transcriptionModeKey),
                let mode = TranscriptionMode(rawValue: rawValue)
            else {
                return .literal
            }
            return mode
        }
        set {
            objectWillChange.send()
            defaults.set(newValue.rawValue, forKey: Self.transcriptionModeKey)
            statusMessage = "Mode: \(newValue.title)"
        }
    }

    private var defaultCLIPath: String {
        workspaceRoot + "/vendors/whisper.cpp/build/bin/whisper-cli"
    }

    private var defaultModelPath: String {
        workspaceRoot + "/models/ggml-small.bin"
    }

    private var defaultCodexPath: String {
        "/Applications/Codex.app/Contents/Resources/codex"
    }

    private static func detectWorkspaceRoot() -> String {
        let fileManager = FileManager.default
        let bundleURL = Bundle.main.bundleURL.standardizedFileURL

        let candidateRoots = [
            bundleURL
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent(),
            URL(fileURLWithPath: fileManager.currentDirectoryPath),
        ]

        for candidate in candidateRoots {
            let root = candidate.standardizedFileURL
            let xcodeproj = root.appendingPathComponent("MiWhisper.xcodeproj").path
            let readme = root.appendingPathComponent("README.md").path
            if fileManager.fileExists(atPath: xcodeproj) || fileManager.fileExists(atPath: readme) {
                return root.path
            }
        }

        return fileManager.homeDirectoryForCurrentUser.path
    }

    let modelPresets = [
        WhisperModelPreset(
            id: "small",
            title: "Small",
            filename: "ggml-small.bin",
            detail: "Punto de partida rápido",
            sizeDescription: "466 MiB",
            approximateBytes: 466 * 1_048_576
        ),
        WhisperModelPreset(
            id: "large-v3-turbo-q5_0",
            title: "Large v3 Turbo q5",
            filename: "ggml-large-v3-turbo-q5_0.bin",
            detail: "Mejor candidato para subir calidad sin matar la UX",
            sizeDescription: "547 MiB",
            approximateBytes: 547 * 1_048_576
        ),
        WhisperModelPreset(
            id: "medium",
            title: "Medium",
            filename: "ggml-medium.bin",
            detail: "Más pesado; úsalo solo si compensa",
            sizeDescription: "1.5 GiB",
            approximateBytes: 1_610_612_736
        ),
    ]

    private init() {
        loadTranscriptHistory()
        loadUsageDailyBuckets()
        hasHotkeyMonitor = HotkeyMonitor.shared.isAvailable
        syncLaunchAtLoginState()

        modelDownloader.onProgress = { [weak self] presetID, bytesWritten, totalBytesExpected, startedAt in
            self?.handleModelDownloadProgress(
                presetID: presetID,
                bytesWritten: bytesWritten,
                totalBytesExpected: totalBytesExpected,
                startedAt: startedAt
            )
        }

        modelDownloader.onCompletion = { [weak self] presetID, result in
            self?.handleModelDownloadCompletion(presetID: presetID, result: result)
        }

        NotificationCenter.default.addObserver(
            forName: HotkeyMonitor.didPressHotkeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                guard let self else { return }
                let intent = HotkeyMonitor.shared.intent(from: notification) ?? .dictation
                self.beginPushToTalk(intent: intent)
            }
        }

        NotificationCenter.default.addObserver(
            forName: HotkeyMonitor.didReleaseHotkeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                guard let self else { return }
                let intent = HotkeyMonitor.shared.intent(from: notification) ?? self.currentHotkeyIntent
                self.endPushToTalk(intent: intent)
            }
        }

        NotificationCenter.default.addObserver(
            forName: HotkeyMonitor.didChangeAvailabilityNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                self?.hasHotkeyMonitor = notification.userInfo?["isAvailable"] as? Bool ?? false
            }
        }
    }

    func requestInitialPermissions() {
        refreshPermissionStatus()

        requestAccessibilityPermissionIfNeeded()
        requestInputMonitoringPermissionIfNeeded()

        AVCaptureDevice.requestAccess(for: .audio) { granted in
            Task { @MainActor in
                self.hasMicrophoneAccess = granted
                if !granted {
                    self.errorMessage = "Microphone access is required."
                    self.statusMessage = "Waiting for microphone permission"
                }
            }
        }

        if !CGPreflightListenEventAccess() {
            _ = CGRequestListenEventAccess()
        }

        notifier.requestAuthorizationIfNeeded()
        HotkeyMonitor.shared.refresh()

        refreshPermissionStatus()
    }

    func requestAccessibilityPermissionIfNeeded() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        hasAccessibilityAccess = AXIsProcessTrustedWithOptions(options)

        if !hasAccessibilityAccess {
            statusMessage = "Waiting for Accessibility permission"
        }
    }

    func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            return
        }

        NSWorkspace.shared.open(url)
    }

    func requestInputMonitoringPermissionIfNeeded() {
        if !CGPreflightListenEventAccess() {
            _ = CGRequestListenEventAccess()
        }

        hasInputMonitoringAccess = CGPreflightListenEventAccess()
    }

    func openInputMonitoringSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") else {
            return
        }

        NSWorkspace.shared.open(url)
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }

                defaults.set(enabled, forKey: Self.launchAtLoginPreferenceKey)
                launchAtLoginErrorMessage = nil
                syncLaunchAtLoginState()
                statusMessage = enabled ? "Launch at login enabled" : "Launch at login disabled"
            } catch {
                syncLaunchAtLoginState()
                launchAtLoginErrorMessage = error.localizedDescription
                statusMessage = "Could not change launch at login"
            }
            return
        }

        launchAtLoginErrorMessage = "Launch at login requires macOS 13 or later."
    }

    func openLoginItemsSettings() {
        if #available(macOS 13.0, *) {
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    func syncLaunchAtLoginState() {
        if #available(macOS 13.0, *) {
            let status = SMAppService.mainApp.status
            launchAtLoginEnabled = status == .enabled
            launchAtLoginRequiresApproval = status == .requiresApproval

            if status == .notFound {
                launchAtLoginEnabled = defaults.bool(forKey: Self.launchAtLoginPreferenceKey)
            }
            return
        }

        launchAtLoginEnabled = false
        launchAtLoginRequiresApproval = false
    }

    func toggleRecording() {
        if isRecording {
            endPushToTalk(intent: currentHotkeyIntent)
        } else {
            beginPushToTalk(intent: .dictation)
        }
    }

    func pasteLastTranscript() {
        guard !lastTranscript.isEmpty else { return }

        Task {
            await pasteTranscript(lastTranscript)
        }
    }

    func copyLastTranscript() {
        guard !lastTranscript.isEmpty else { return }
        paster.copyToClipboard(lastTranscript)
        statusMessage = "Transcript copied"
    }

    func copyTranscriptHistoryEntry(_ entry: TranscriptEntry) {
        let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        lastTranscript = text
        paster.copyToClipboard(text)
        statusMessage = "Transcript copied"
        notifier.post(
            title: "MiWhisper copied a saved transcript",
            body: "The saved transcript is now in your clipboard."
        )
    }

    func resetPathsToDefaults() {
        cliPath = defaultCLIPath
        modelPath = defaultModelPath
        codexPath = defaultCodexPath
        language = "auto"
        transcriptionMode = .literal
        codexDefaultModel = ""
        codexReasoningEffort = .useConfigDefault
        codexServiceTier = .useConfigDefault
    }

    func path(for preset: WhisperModelPreset) -> String {
        workspaceRoot + "/models/" + preset.filename
    }

    func isModelInstalled(_ preset: WhisperModelPreset) -> Bool {
        FileManager.default.fileExists(atPath: path(for: preset))
    }

    var selectedModelPresetID: String? {
        modelPresets.first { preset in
            path(for: preset) == modelPath
        }?.id
    }

    func selectModelPreset(_ preset: WhisperModelPreset) {
        guard isModelInstalled(preset) else {
            statusMessage = "Download \(preset.title) first"
            return
        }

        modelPath = path(for: preset)
        statusMessage = "Selected model: \(preset.title)"
    }

    func isDownloading(_ preset: WhisperModelPreset) -> Bool {
        modelDownloadState?.presetID == preset.id
    }

    func canDownload(_ preset: WhisperModelPreset) -> Bool {
        if isModelInstalled(preset) {
            return false
        }

        if let modelDownloadState, modelDownloadState.presetID != preset.id {
            return false
        }

        return true
    }

    func downloadModelPreset(_ preset: WhisperModelPreset) {
        guard !isModelInstalled(preset) else {
            selectModelPreset(preset)
            return
        }

        guard canDownload(preset) else {
            statusMessage = "Another model download is already in progress"
            return
        }

        errorMessage = nil
        statusMessage = "Downloading \(preset.title)..."
        modelDownloadState = ModelDownloadState(
            presetID: preset.id,
            bytesWritten: 0,
            totalBytesExpected: preset.approximateBytes,
            startedAt: Date()
        )

        modelDownloader.startDownload(
            presetID: preset.id,
            sourceURL: preset.downloadURL,
            destinationURL: URL(fileURLWithPath: path(for: preset))
        )
    }

    func downloadProgressValue(for preset: WhisperModelPreset) -> Double? {
        guard let modelDownloadState, modelDownloadState.presetID == preset.id else {
            return nil
        }

        let totalBytes = resolvedTotalBytes(for: preset, state: modelDownloadState)
        guard totalBytes > 0 else {
            return nil
        }

        return min(max(Double(modelDownloadState.bytesWritten) / Double(totalBytes), 0), 1)
    }

    func downloadStatusText(for preset: WhisperModelPreset) -> String? {
        guard let modelDownloadState, modelDownloadState.presetID == preset.id else {
            return nil
        }

        let totalBytes = resolvedTotalBytes(for: preset, state: modelDownloadState)
        let bytesWritten = max(modelDownloadState.bytesWritten, 0)
        let writtenLabel = Self.byteCountFormatter.string(fromByteCount: bytesWritten)
        let totalLabel = totalBytes > 0
            ? Self.byteCountFormatter.string(fromByteCount: totalBytes)
            : preset.sizeDescription

        var parts = ["\(writtenLabel) / \(totalLabel)"]

        if let etaLabel = estimatedRemainingText(for: preset, state: modelDownloadState) {
            parts.append(etaLabel)
        }

        return parts.joined(separator: " · ")
    }

    var menuBarSymbolName: String {
        if isRecording {
            let symbols = ["mic.circle.fill", "waveform.circle.fill", "dot.radiowaves.left.and.right"]
            return symbols[recordingPulse % symbols.count]
        }

        if isTranscribing {
            let symbols = ["ellipsis.circle", "ellipsis.circle.fill", "waveform"]
            return symbols[recordingPulse % symbols.count]
        }

        return "waveform"
    }

    var permissionSummary: String {
        if !hasHotkeyMonitor { return "Fn hotkey inactive" }
        if !hasAccessibilityAccess { return "Accessibility missing" }
        if !hasMicrophoneAccess { return "Microphone missing" }
        if !hasInputMonitoringAccess { return "Ready (Fn needs Input Monitoring)" }
        return "Ready"
    }

    private func beginPushToTalk(intent: HotkeyIntent) {
        NSLog(
            "[MiWhisper][AppState] beginPushToTalk intent=%@ recording=%@ transcribing=%@ codex=%@",
            intent.rawValue,
            isRecording ? "true" : "false",
            isTranscribing ? "true" : "false",
            "false"
        )
        errorMessage = nil
        refreshPermissionStatus()

        if isTranscribing || isRecording {
            NSLog("[MiWhisper][AppState] beginPushToTalk ignored because work is already in progress")
            return
        }

        if !hasMicrophoneAccess {
            NSLog("[MiWhisper][AppState] beginPushToTalk blocked because microphone permission is missing")
            statusMessage = "Grant microphone permission"
            return
        }

        do {
            currentHotkeyIntent = intent
            if intent == .dictation {
                capturePasteTarget()
            } else {
                focusedTarget = nil
            }
            let url = try recorder.startRecording()
            currentRecordingURL = url
            recordingStartedAt = Date()
            isRecording = true
            statusMessage = intent == .codexPrompt ? "Listening for Codex..." : "Listening..."
            startPulseAnimation()
            NSLog("[MiWhisper][AppState] recording started path=%@", url.path)
        } catch {
            currentRecordingURL = nil
            recordingStartedAt = nil
            errorMessage = error.localizedDescription
            statusMessage = "Failed to start recording"
            NSLog("[MiWhisper][AppState] failed to start recording error=%@", error.localizedDescription)
        }
    }

    private func endPushToTalk(intent: HotkeyIntent) {
        guard let recordingURL = currentRecordingURL else {
            NSLog("[MiWhisper][AppState] endPushToTalk ignored because there is no current recording URL")
            return
        }

        let heldDurationMs = recordingStartedAt.map { Date().timeIntervalSince($0) * 1000 } ?? -1
        let audioDurationSeconds = max(recordingStartedAt.map { Date().timeIntervalSince($0) } ?? 0, 0)
        NSLog(
            "[MiWhisper][AppState] endPushToTalk path=%@ heldDurationMs=%.1f",
            recordingURL.path,
            heldDurationMs
        )
        currentRecordingURL = nil
        recordingStartedAt = nil
        recorder.stopRecording()
        isRecording = false
        isTranscribing = true
        currentHotkeyIntent = intent
        startPulseAnimation()
        statusMessage = intent == .codexPrompt ? "Transcribing for Codex..." : "Transcribing..."
        logAudioFileDiagnostics(at: recordingURL, label: "before-transcribe")

        Task {
            do {
                let transcript = try await transcriber.transcribe(
                    audioFileURL: recordingURL,
                    cliPath: cliPath,
                    modelPath: modelPath,
                    language: language,
                    mode: transcriptionMode
                )

                if intent == .codexPrompt {
                    let prompt = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                    lastTranscript = prompt
                    rememberTranscript(prompt)
                    recordUsage(
                        transcript: prompt,
                        intent: intent,
                        mode: transcriptionMode,
                        audioDurationSeconds: audioDurationSeconds
                    )
                    runCodex(for: prompt)
                } else {
                    let formattedTranscript = await preparedTranscriptForInsertion(transcript)
                    lastTranscript = formattedTranscript
                    rememberTranscript(formattedTranscript)
                    recordUsage(
                        transcript: formattedTranscript,
                        intent: intent,
                        mode: transcriptionMode,
                        audioDurationSeconds: audioDurationSeconds
                    )
                    await pasteTranscript(formattedTranscript)
                }
            } catch {
                errorMessage = error.localizedDescription
                statusMessage = intent == .codexPrompt ? "Codex flow failed" : "Transcription failed"
                NSLog("[MiWhisper][AppState] flow failed error=%@", error.localizedDescription)
            }

            deleteTemporaryAudioFile(at: recordingURL)

            isTranscribing = false
            stopPulseAnimation()
            refreshPermissionStatus()
        }
    }

    private func runCodex(for prompt: String) {
        let normalizedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPrompt.isEmpty else {
            statusMessage = "Empty Codex prompt"
            return
        }

        statusMessage = "Opening Codex session..."
        Task { @MainActor in
            CodexSessionManager.shared.openSession(
                prompt: normalizedPrompt,
                executablePath: codexPath,
                workingDirectory: workspaceRoot,
                modelOverride: codexDefaultModel.trimmingCharacters(in: .whitespacesAndNewlines),
                reasoningEffort: codexReasoningEffort,
                serviceTier: codexServiceTier
            )
            self.statusMessage = "Codex session opened"
        }
    }

    private func logAudioFileDiagnostics(at url: URL, label: String) {
        let filePath = url.path
        let fileExists = FileManager.default.fileExists(atPath: filePath)
        let fileSize = ((try? FileManager.default.attributesOfItem(atPath: filePath)[.size]) as? NSNumber)?.int64Value ?? -1

        guard fileExists else {
            NSLog("[MiWhisper][WAV] %@ file missing path=%@", label, filePath)
            return
        }

        do {
            let audioFile = try AVAudioFile(forReading: url)
            let format = audioFile.processingFormat
            let frameCount = audioFile.length
            let sampleRate = format.sampleRate
            let channelCount = format.channelCount
            let durationMs = sampleRate > 0 ? (Double(frameCount) / sampleRate) * 1000 : -1

            NSLog(
                "[MiWhisper][WAV] %@ path=%@ sizeBytes=%lld frames=%lld sampleRate=%.1f channels=%u durationMs=%.1f commonFormat=%ld interleaved=%@",
                label,
                filePath,
                fileSize,
                frameCount,
                sampleRate,
                channelCount,
                durationMs,
                format.commonFormat.rawValue,
                format.isInterleaved ? "true" : "false"
            )
        } catch {
            NSLog(
                "[MiWhisper][WAV] %@ failed to inspect path=%@ sizeBytes=%lld error=%@",
                label,
                filePath,
                fileSize,
                error.localizedDescription
            )
        }
    }

    private func pasteTranscript(_ transcript: String) async {
        refreshPermissionStatus()
        guard !transcript.isEmpty else { return }

        if shouldUseInAppInsertion, inAppInserter.insert(transcript) {
            statusMessage = "Transcript inserted"
            return
        }

        guard let focusedTarget else {
            paster.copyToClipboard(transcript)
            statusMessage = "Copied to clipboard"
            notifier.post(
                title: "MiWhisper copied the transcript",
                body: "No app was available to paste into. The text is now in your clipboard."
            )
            return
        }

        guard hasAccessibilityAccess else {
            paster.copyToClipboard(transcript)
            statusMessage = "Copied to clipboard"
            notifier.post(
                title: "MiWhisper could not paste",
                body: "Accessibility permission is missing. The transcript is in your clipboard."
            )
            return
        }

        var insertionTarget = inserter.refreshFocusedTarget(from: focusedTarget)
        if inserter.insert(transcript, into: insertionTarget) {
            rememberSuccessfulInsertion(of: transcript, into: insertionTarget)
            statusMessage = "Transcript inserted"
            return
        }

        guard focusedTarget.application.activate(options: []) else {
            paster.copyToClipboard(transcript)
            statusMessage = "Copied to clipboard"
            notifier.post(
                title: "MiWhisper could not focus the target app",
                body: "The transcript is in your clipboard so you can paste it manually."
            )
            return
        }

        try? await Task.sleep(for: .milliseconds(280))

        insertionTarget = inserter.refreshFocusedTarget(from: focusedTarget)
        if inserter.insert(transcript, into: insertionTarget) {
            rememberSuccessfulInsertion(of: transcript, into: insertionTarget)
            statusMessage = "Transcript inserted"
            return
        }

        do {
            let clipboardSnapshot = paster.captureClipboardSnapshot()
            paster.copyToClipboard(transcript)
            try? await Task.sleep(for: .milliseconds(140))
            try paster.pasteClipboardContents()
            try? await Task.sleep(for: .milliseconds(180))
            paster.restoreClipboardSnapshot(clipboardSnapshot)
            rememberSuccessfulInsertion(of: transcript, into: insertionTarget)
            statusMessage = "Transcript pasted"
        } catch {
            paster.copyToClipboard(transcript)
            errorMessage = error.localizedDescription
            statusMessage = "Copied to clipboard"
            notifier.post(
                title: "MiWhisper copied the transcript",
                body: "Paste failed, but the transcript is in your clipboard."
            )
        }
    }

    private func capturePasteTarget() {
        let ownBundleID = Bundle.main.bundleIdentifier
        focusedTarget = inserter.captureFocusedTarget(excluding: ownBundleID)
        shouldUseInAppInsertion = focusedTarget == nil && inAppInserter.hasActiveTarget
    }

    private func preparedTranscriptForInsertion(_ transcript: String) async -> String {
        let context = formattingContextForCurrentTarget()
        return textFormatter.format(transcript, context: context)
    }

    private func formattingContextForCurrentTarget() -> TextContinuationFormatter.Context {
        if shouldUseInAppInsertion, let insertionContext = inAppInserter.insertionContext() {
            return TextContinuationFormatter.Context(
                precedingCharacter: insertionContext.precedingCharacter,
                hasSelection: insertionContext.hasSelection
            )
        }

        guard let focusedTarget else {
            return TextContinuationFormatter.Context(precedingCharacter: nil, hasSelection: false)
        }

        let refreshedTarget = inserter.refreshFocusedTarget(from: focusedTarget)
        if let insertionContext = inserter.insertionContext(for: refreshedTarget) {
            return TextContinuationFormatter.Context(
                precedingCharacter: insertionContext.precedingCharacter,
                hasSelection: insertionContext.hasSelection
            )
        }

        if let lastInsertionState, lastInsertionState.processIdentifier == refreshedTarget.application.processIdentifier {
            return TextContinuationFormatter.Context(
                precedingCharacter: lastInsertionState.trailingCharacter,
                hasSelection: false
            )
        }

        return TextContinuationFormatter.Context(precedingCharacter: nil, hasSelection: false)
    }

    private func rememberSuccessfulInsertion(of transcript: String, into target: AccessibilityTextInsertion.FocusedTarget) {
        let normalized = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let trailingCharacter = normalized.last
        let trailingContext = String(normalized.suffix(120))

        lastInsertionState = LastInsertionState(
            processIdentifier: target.application.processIdentifier,
            trailingCharacter: trailingCharacter,
            trailingContext: trailingContext
        )
    }

    private func refreshPermissionStatus() {
        hasMicrophoneAccess = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        hasAccessibilityAccess = AXIsProcessTrusted()
        hasInputMonitoringAccess = CGPreflightListenEventAccess()
        hasHotkeyMonitor = HotkeyMonitor.shared.isAvailable
        notifier.refreshAuthorizationStatus { authorized in
            self.hasNotificationAccess = authorized
        }
    }

    private func startPulseAnimation() {
        pulseTask?.cancel()
        pulseTask = Task { @MainActor in
            while isRecording || isTranscribing {
                recordingPulse += 1
                try? await Task.sleep(for: .milliseconds(320))
            }
        }
    }

    private func stopPulseAnimation() {
        pulseTask?.cancel()
        pulseTask = nil
        recordingPulse = 0
    }

    private func rememberTranscript(_ transcript: String) {
        let normalized = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }

        transcriptHistory.removeAll { $0.text == normalized }
        transcriptHistory.insert(
            TranscriptEntry(id: UUID(), text: normalized, createdAt: Date()),
            at: 0
        )

        if transcriptHistory.count > Self.maxTranscriptHistory {
            transcriptHistory = Array(transcriptHistory.prefix(Self.maxTranscriptHistory))
        }

        saveTranscriptHistory()
    }

    private func deleteTemporaryAudioFile(at url: URL) {
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
                NSLog("[MiWhisper][WAV] deleted temporary file path=%@", url.path)
            }
        } catch {
            NSLog(
                "[MiWhisper][WAV] failed to delete temporary file path=%@ error=%@",
                url.path,
                error.localizedDescription
            )
        }
    }

    private func loadTranscriptHistory() {
        guard let data = defaults.data(forKey: Self.transcriptHistoryKey) else { return }
        guard let decoded = try? JSONDecoder().decode([TranscriptEntry].self, from: data) else { return }
        transcriptHistory = decoded
    }

    private func loadUsageDailyBuckets() {
        guard let data = defaults.data(forKey: Self.usageDailyBucketsKey) else { return }
        guard let decoded = try? JSONDecoder().decode([UsageDayBucket].self, from: data) else { return }
        usageDailyBuckets = decoded.sorted { $0.dayStart > $1.dayStart }
    }

    func reloadTranscriptHistory() {
        loadTranscriptHistory()
    }

    func reloadUsageDailyBuckets() {
        loadUsageDailyBuckets()
    }

    private func saveTranscriptHistory() {
        guard let data = try? JSONEncoder().encode(transcriptHistory) else { return }
        defaults.set(data, forKey: Self.transcriptHistoryKey)
    }

    private func saveUsageDailyBuckets() {
        guard let data = try? JSONEncoder().encode(usageDailyBuckets) else { return }
        defaults.set(data, forKey: Self.usageDailyBucketsKey)
    }

    var hasUsageStats: Bool {
        usageDailyBuckets.contains { $0.totalUses > 0 }
    }

    func usageSnapshot(for period: UsageStatsPeriod) -> UsageStatsSnapshot {
        let buckets = usageBuckets(for: period)
        guard !buckets.isEmpty else { return .empty }

        return UsageStatsSnapshot(
            dictationCount: buckets.reduce(0) { $0 + $1.dictationCount },
            codexPromptCount: buckets.reduce(0) { $0 + $1.codexPromptCount },
            literalCount: buckets.reduce(0) { $0 + $1.literalCount },
            translationCount: buckets.reduce(0) { $0 + $1.translationCount },
            wordCount: buckets.reduce(0) { $0 + $1.wordCount },
            characterCount: buckets.reduce(0) { $0 + $1.characterCount },
            audioSeconds: buckets.reduce(0) { $0 + $1.audioSeconds },
            estimatedTypingSeconds: buckets.reduce(0) { $0 + $1.estimatedTypingSeconds }
        )
    }

    func usageChartPoints(lastDays: Int = 14) -> [UsageChartPoint] {
        guard lastDays > 0 else { return [] }

        let calendar = Calendar.autoupdatingCurrent
        let today = calendar.startOfDay(for: Date())
        let lookup = Dictionary(uniqueKeysWithValues: usageDailyBuckets.map { (calendar.startOfDay(for: $0.dayStart), $0) })

        return (0..<lastDays).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -(lastDays - offset - 1), to: today) else {
                return nil
            }

            let bucket = lookup[day]
            return UsageChartPoint(
                dayStart: day,
                uses: bucket?.totalUses ?? 0,
                savedMinutes: max((bucket?.estimatedSavedSeconds ?? 0) / 60.0, 0)
            )
        }
    }

    private func usageBuckets(for period: UsageStatsPeriod) -> [UsageDayBucket] {
        let calendar = Calendar.autoupdatingCurrent
        let now = Date()

        switch period {
        case .allTime:
            return usageDailyBuckets
        case .day:
            let start = calendar.startOfDay(for: now)
            return usageDailyBuckets.filter { $0.dayStart >= start }
        case .week:
            guard let interval = calendar.dateInterval(of: .weekOfYear, for: now) else { return [] }
            return usageDailyBuckets.filter { $0.dayStart >= interval.start }
        case .month:
            guard let interval = calendar.dateInterval(of: .month, for: now) else { return [] }
            return usageDailyBuckets.filter { $0.dayStart >= interval.start }
        case .year:
            guard let interval = calendar.dateInterval(of: .year, for: now) else { return [] }
            return usageDailyBuckets.filter { $0.dayStart >= interval.start }
        }
    }

    private func recordUsage(
        transcript: String,
        intent: HotkeyIntent,
        mode: TranscriptionMode,
        audioDurationSeconds: Double
    ) {
        let normalized = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }

        let words = normalized.split(whereSeparator: \.isWhitespace).count
        let characters = normalized.count
        let typingSeconds = words > 0 ? (Double(words) / Self.estimatedTypingWordsPerMinute) * 60.0 : 0
        let calendar = Calendar.autoupdatingCurrent
        let dayStart = calendar.startOfDay(for: Date())

        if let index = usageDailyBuckets.firstIndex(where: { calendar.isDate($0.dayStart, inSameDayAs: dayStart) }) {
            usageDailyBuckets[index].record(
                intent: intent,
                mode: mode,
                wordCount: words,
                characterCount: characters,
                audioSeconds: audioDurationSeconds,
                estimatedTypingSeconds: typingSeconds
            )
        } else {
            var bucket = UsageDayBucket(
                dayStart: dayStart,
                dictationCount: 0,
                codexPromptCount: 0,
                literalCount: 0,
                translationCount: 0,
                wordCount: 0,
                characterCount: 0,
                audioSeconds: 0,
                estimatedTypingSeconds: 0
            )
            bucket.record(
                intent: intent,
                mode: mode,
                wordCount: words,
                characterCount: characters,
                audioSeconds: audioDurationSeconds,
                estimatedTypingSeconds: typingSeconds
            )
            usageDailyBuckets.insert(bucket, at: 0)
        }

        usageDailyBuckets.sort { $0.dayStart > $1.dayStart }
        if usageDailyBuckets.count > Self.maxUsageDailyBuckets {
            usageDailyBuckets = Array(usageDailyBuckets.prefix(Self.maxUsageDailyBuckets))
        }
        saveUsageDailyBuckets()
    }

    private func handleModelDownloadProgress(
        presetID: String,
        bytesWritten: Int64,
        totalBytesExpected: Int64,
        startedAt: Date
    ) {
        modelDownloadState = ModelDownloadState(
            presetID: presetID,
            bytesWritten: bytesWritten,
            totalBytesExpected: totalBytesExpected,
            startedAt: startedAt
        )

        if let preset = modelPresets.first(where: { $0.id == presetID }) {
            statusMessage = "Downloading \(preset.title)..."
        }
    }

    private func handleModelDownloadCompletion(presetID: String, result: Result<Void, Error>) {
        modelDownloadState = nil

        guard let preset = modelPresets.first(where: { $0.id == presetID }) else {
            return
        }

        switch result {
        case .success:
            modelPath = path(for: preset)
            statusMessage = "Downloaded and selected \(preset.title)"
        case let .failure(error):
            errorMessage = "Model download failed: \(error.localizedDescription)"
            statusMessage = "Model download failed"
        }
    }

    private func resolvedTotalBytes(for preset: WhisperModelPreset, state: ModelDownloadState) -> Int64 {
        if state.totalBytesExpected > 0 {
            return state.totalBytesExpected
        }

        return preset.approximateBytes
    }

    private func estimatedRemainingText(for preset: WhisperModelPreset, state: ModelDownloadState) -> String? {
        let totalBytes = resolvedTotalBytes(for: preset, state: state)
        guard totalBytes > 0, state.bytesWritten > 0 else {
            return nil
        }

        let elapsed = Date().timeIntervalSince(state.startedAt)
        guard elapsed > 0 else {
            return nil
        }

        let bytesPerSecond = Double(state.bytesWritten) / elapsed
        guard bytesPerSecond > 0 else {
            return nil
        }

        let remainingBytes = Double(max(totalBytes - state.bytesWritten, 0))
        let remainingSeconds = remainingBytes / bytesPerSecond
        guard remainingSeconds.isFinite, remainingSeconds > 1 else {
            return "Almost done"
        }

        guard let duration = Self.durationFormatter.string(from: remainingSeconds) else {
            return nil
        }

        return "About \(duration) left"
    }

    private static let byteCountFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .binary
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter
    }()

    private static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter
    }()
}
