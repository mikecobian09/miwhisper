import AVFoundation
import UIKit

@MainActor
final class CarModeRunWatcher: ObservableObject {
    private struct SessionDetail: Decodable {
        let session: Session
        let activity: [ActivityEntry]?
        let live: LiveStatus?
    }

    private struct Session: Decodable {
        let id: String
        let title: String?
        let isBusy: Bool
        let latestResponse: String?
    }

    private struct ActivityEntry: Decodable {
        let id: String?
        let sourceID: String?
        let groupID: String?
        let kind: String?
        let blockKind: String?
        let title: String?
        let detail: String?
    }

    private struct LiveStatus: Decodable {
        let state: String?
        let label: String?
        let detail: String?
        let needsAttention: Bool?
    }

    private let speechController: NativeSpeechController
    private var watchTask: Task<Void, Never>?
    private var watchedSessionID: String?
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var audioEngine: AVAudioEngine?
    private var audioPlayer: AVAudioPlayerNode?
    private var busyStartedAt: Date?
    private var lastProgressSpokenAt: Date?
    private var lastProgressKey: String?

    init(speechController: NativeSpeechController) {
        self.speechController = speechController
    }

    func watch(baseURL: URL, sessionID: String, verbosity: String) {
        let cleanSessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanSessionID.isEmpty else { return }
        if watchedSessionID == cleanSessionID, watchTask != nil { return }

        stop()
        watchedSessionID = cleanSessionID
        beginBackgroundTask()
        startKeepAliveAudio()

        watchTask = Task { [weak self] in
            await self?.poll(baseURL: baseURL, sessionID: cleanSessionID, verbosity: verbosity)
        }
    }

    func stop() {
        watchTask?.cancel()
        watchTask = nil
        watchedSessionID = nil
        stopKeepAliveAudio()
        endBackgroundTask()
        busyStartedAt = nil
        lastProgressSpokenAt = nil
        lastProgressKey = nil
    }

    private func poll(baseURL: URL, sessionID: String, verbosity: String) async {
        var failureCount = 0
        let startedAt = Date()

        while !Task.isCancelled {
            if Date().timeIntervalSince(startedAt) > 25 * 60 {
                stop()
                return
            }

            do {
                let detail = try await fetchDetail(baseURL: baseURL, sessionID: sessionID)
                failureCount = 0

                if shouldSpeakAttention(detail) {
                    speakAndStop("Necesito atención. \(attentionText(detail))", key: "car-attention-\(sessionID)")
                    return
                }

                if !detail.session.isBusy {
                    let text = spokenFinalSummary(detail, verbosity: verbosity)
                    if text.isEmpty {
                        speakAndStop("He terminado, pero no encuentro una respuesta legible para leer.", key: "car-empty-\(sessionID)")
                    } else {
                        speakAndStop(text, key: "car-final-\(sessionID)")
                    }
                    return
                }

                speakProgressIfNeeded(detail, sessionID: sessionID, verbosity: verbosity)
            } catch {
                failureCount += 1
                if failureCount >= 8 {
                    stop()
                    return
                }
            }

            let delay = min(2.0 + Double(failureCount), 6.0)
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }

    private func fetchDetail(baseURL: URL, sessionID: String) async throws -> SessionDetail {
        let encoded = sessionID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? sessionID
        let url = baseURL.appending(path: "api/sessions/\(encoded)")
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(SessionDetail.self, from: data)
    }

    private func shouldSpeakAttention(_ detail: SessionDetail) -> Bool {
        let state = detail.live?.state?.lowercased()
        if state == "attention" || detail.live?.needsAttention == true { return true }
        return state == "error" && !detail.session.isBusy
    }

    private func attentionText(_ detail: SessionDetail) -> String {
        let raw = detail.live?.detail ?? detail.live?.label ?? "Codex necesita una decisión cuando estés parado."
        return compact(raw, maxCharacters: 260)
    }

    private func spokenFinalSummary(_ detail: SessionDetail, verbosity: String) -> String {
        let finalText = latestFinalText(detail)
        guard !finalText.isEmpty else { return "" }
        let summary = carSummary(from: finalText, verbosity: verbosity)
        guard !summary.isEmpty else { return "" }
        return "He terminado. \(summary)"
    }

    private func speakProgressIfNeeded(_ detail: SessionDetail, sessionID: String, verbosity: String) {
        let now = Date()
        if busyStartedAt == nil {
            busyStartedAt = now
            return
        }
        let timing = progressTiming(verbosity: verbosity)
        guard let busyStartedAt, now.timeIntervalSince(busyStartedAt) >= timing.firstDelay else { return }
        if let lastProgressSpokenAt, now.timeIntervalSince(lastProgressSpokenAt) < timing.cooldown {
            return
        }

        let phrase = progressNarration(detail)
        guard !phrase.isEmpty else { return }
        let key = progressKey(detail)
        if key == lastProgressKey, let lastProgressSpokenAt, now.timeIntervalSince(lastProgressSpokenAt) < timing.cooldown * 2 {
            return
        }

        lastProgressKey = key
        lastProgressSpokenAt = now
        speechController.speak(text: phrase, key: "car-progress-\(sessionID)-\(Int(now.timeIntervalSince1970))", language: "es-ES", rate: 0.52, pitch: 1.0)
    }

    private func progressTiming(verbosity: String) -> (firstDelay: TimeInterval, cooldown: TimeInterval) {
        switch verbosity {
        case "detail":
            return (22, 38)
        case "normal":
            return (32, 55)
        default:
            return (48, 85)
        }
    }

    private func progressNarration(_ detail: SessionDetail) -> String {
        let state = detail.live?.state?.lowercased() ?? ""
        let latest = latestNarratableProgressEntry(detail)
        let source = narratableProgressText(latest?.detail ?? detail.live?.detail ?? "")

        if state == "error" {
            return "Ha aparecido un fallo intermedio. Codex sigue trabajando; te avisare si acaba bloqueado."
        }

        let kind = latest?.blockKind?.lowercased() ?? detail.live?.state?.lowercased() ?? ""
        switch kind {
        case "reasoning", "thinking":
            return source.isEmpty ? "Estoy pensando y organizando la siguiente accion." : "Estoy pensando. \(source)"
        case "patch":
            return source.isEmpty ? "Estoy editando archivos en tu Mac." : "Estoy editando archivos. \(source)"
        case "command":
            return "Estoy ejecutando comandos en tu Mac."
        case "tool":
            return source.isEmpty ? "Estoy usando herramientas y revisando resultados." : "Estoy revisando resultados. \(source)"
        case "streaming", "final":
            return "Estoy redactando la respuesta."
        default:
            return "Sigo trabajando en tu Mac."
        }
    }

    private func latestNarratableProgressEntry(_ detail: SessionDetail) -> ActivityEntry? {
        guard let activity = detail.activity else { return nil }
        for entry in activity.reversed() {
            guard let blockKind = entry.blockKind?.lowercased(),
                  ["reasoning", "patch", "command", "tool"].contains(blockKind) else {
                continue
            }
            let kind = entry.kind?.lowercased()
            if kind == "error" || kind == "warning" { continue }
            return entry
        }
        return nil
    }

    private func narratableProgressText(_ text: String) -> String {
        let clean = normalizeSpeechText(text)
        guard !clean.isEmpty else { return "" }
        if clean.range(of: #"(?m)^(diff --git|@@|\+\+\+|---|stdout|stderr|traceback|exception|error|warning)\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return ""
        }
        let prefix = String(clean.prefix(220))
        if prefix.range(of: #"[{}()[\];=<>]"#, options: .regularExpression) != nil,
           prefix.split(separator: " ").count < 18 {
            return ""
        }
        return limitSentences(clean, maxSentences: 1, maxCharacters: 190)
    }

    private func progressKey(_ detail: SessionDetail) -> String {
        let latest = latestNarratableProgressEntry(detail)
        let sessionID = detail.session.id
        let liveState = detail.live?.state ?? ""
        let liveLabel = detail.live?.label ?? ""
        let entryID = latest?.id ?? latest?.sourceID ?? latest?.groupID ?? latest?.title ?? ""
        let detailText = latest?.detail ?? detail.live?.detail ?? ""
        let compactDetail = compact(detailText, maxCharacters: 60)
        return [sessionID, liveState, liveLabel, entryID, compactDetail].joined(separator: "|")
    }

    private func latestFinalText(_ detail: SessionDetail) -> String {
        if let activity = detail.activity {
            for entry in activity.reversed() {
                if entry.blockKind == "final", let text = entry.detail?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                    return text
                }
            }
        }
        return detail.session.latestResponse?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func carSummary(from text: String, verbosity: String) -> String {
        let clean = normalizeSpeechText(text)
        guard !clean.isEmpty else { return "" }
        let source = explicitCarSummary(from: clean) ?? clean

        switch verbosity {
        case "detail":
            return limitSentences(source, maxSentences: 8, maxCharacters: 980)
        case "normal":
            return limitSentences(source, maxSentences: 4, maxCharacters: 560)
        default:
            return limitSentences(source, maxSentences: 2, maxCharacters: 300)
        }
    }

    private func normalizeSpeechText(_ text: String) -> String {
        var output = text
        output = output.replacingOccurrences(of: #"```[\s\S]*?```"#, with: " Bloque de codigo omitido. ", options: .regularExpression)
        output = output.replacingOccurrences(of: #"`([^`]+)`"#, with: "$1", options: .regularExpression)
        output = output.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
        output = output.replacingOccurrences(of: #"(?m)^#{1,6}\s+"#, with: "", options: .regularExpression)
        output = output.replacingOccurrences(of: #"(?m)^>\s?"#, with: "", options: .regularExpression)
        output = output.replacingOccurrences(of: #"(?m)^\s*[-*+]\s+"#, with: "", options: .regularExpression)
        output = output.replacingOccurrences(of: #"(?m)^\s*\d+\.\s+"#, with: "", options: .regularExpression)
        output = output.replacingOccurrences(of: #"[*_~#>|]"#, with: "", options: .regularExpression)
        output = output.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func explicitCarSummary(from text: String) -> String? {
        guard let range = text.range(of: "resumen para coche", options: [.caseInsensitive, .diacriticInsensitive]) else {
            return nil
        }
        let remainder = String(text[range.upperBound...])
            .trimmingCharacters(in: CharacterSet(charactersIn: " :\n\t"))
        guard !remainder.isEmpty else { return nil }
        if let nextSection = remainder.range(of: #"\s+[A-ZÁÉÍÓÚÑ][^:\n]{2,48}:\s+"#, options: .regularExpression) {
            return String(remainder[..<nextSection.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return remainder
    }

    private func limitSentences(_ text: String, maxSentences: Int, maxCharacters: Int) -> String {
        let normalized = text
            .replacingOccurrences(of: #"\b(diff|patch|tool|output|stdout|stderr)\b"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return "" }

        let regex = try? NSRegularExpression(pattern: #"[^.!?]+[.!?]+|[^.!?]+$"#)
        let range = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
        let matches = regex?.matches(in: normalized, range: range) ?? []
        var result = ""
        var count = 0

        for match in matches {
            guard let sentenceRange = Range(match.range, in: normalized) else { continue }
            let sentence = normalized[sentenceRange].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sentence.isEmpty else { continue }
            let candidate = result.isEmpty ? sentence : "\(result) \(sentence)"
            if candidate.count > maxCharacters { break }
            result = candidate
            count += 1
            if count >= maxSentences { break }
        }

        if result.isEmpty {
            result = String(normalized.prefix(maxCharacters)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return compact(result, maxCharacters: maxCharacters)
    }

    private func compact(_ text: String, maxCharacters: Int) -> String {
        let compacted = text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard compacted.count > maxCharacters else { return compacted }
        return String(compacted.prefix(maxCharacters - 1)).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }

    private func speakAndStop(_ text: String, key: String) {
        stopKeepAliveAudio()
        speechController.speak(text: text, key: key, language: "es-ES", rate: 0.52, pitch: 1.0)
        watchTask?.cancel()
        watchTask = nil
        watchedSessionID = nil
        endBackgroundTask()
    }

    private func beginBackgroundTask() {
        endBackgroundTask()
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "MiWhisperCarModeWatch") { [weak self] in
            Task { @MainActor in
                self?.stop()
            }
        }
    }

    private func endBackgroundTask() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }

    private func startKeepAliveAudio() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [.mixWithOthers])
            try session.setActive(true)

            let engine = AVAudioEngine()
            let player = AVAudioPlayerNode()
            engine.attach(player)

            guard let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100) else {
                return
            }
            buffer.frameLength = buffer.frameCapacity
            if let channel = buffer.floatChannelData?[0] {
                channel.initialize(repeating: 0, count: Int(buffer.frameLength))
            }

            engine.connect(player, to: engine.mainMixerNode, format: format)
            try engine.start()
            player.scheduleBuffer(buffer, at: nil, options: [.loops])
            player.play()

            audioEngine = engine
            audioPlayer = player
        } catch {
            stopKeepAliveAudio()
        }
    }

    private func stopKeepAliveAudio() {
        audioPlayer?.stop()
        audioEngine?.stop()
        audioPlayer = nil
        audioEngine = nil
    }
}
