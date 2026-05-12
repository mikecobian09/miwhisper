import AVFoundation

@MainActor
final class NativeSpeechController: NSObject, ObservableObject, @preconcurrency AVSpeechSynthesizerDelegate {
    struct Event {
        let type: String
        let key: String?
        let message: String?
        let voiceName: String?
        let voiceLanguage: String?
        let voiceQuality: String?

        init(
            type: String,
            key: String?,
            message: String?,
            voiceName: String? = nil,
            voiceLanguage: String? = nil,
            voiceQuality: String? = nil
        ) {
            self.type = type
            self.key = key
            self.message = message
            self.voiceName = voiceName
            self.voiceLanguage = voiceLanguage
            self.voiceQuality = voiceQuality
        }

        var dictionary: [String: Any] {
            [
                "type": type,
                "key": key ?? "",
                "message": message ?? "",
                "voiceName": voiceName ?? "",
                "voiceLanguage": voiceLanguage ?? "",
                "voiceQuality": voiceQuality ?? "",
            ]
        }
    }

    private let synthesizer = AVSpeechSynthesizer()
    private var activeKey: String?
    var onEvent: ((Event) -> Void)?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(text: String, key: String?, language: String?, rate: Double?, pitch: Double?) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            onEvent?(Event(type: "error", key: key, message: "No text to speak."))
            return
        }

        configureAudioSession()
        synthesizer.stopSpeaking(at: .immediate)
        activeKey = key

        let utterance = AVSpeechUtterance(string: clean)
        let selectedVoice = preferredVoice(language: language)
        utterance.voice = selectedVoice
        let rateValue = rate.map(Float.init) ?? AVSpeechUtteranceDefaultSpeechRate
        utterance.rate = rateValue
        utterance.pitchMultiplier = Float(pitch ?? 1.0)
        utterance.preUtteranceDelay = 0
        utterance.postUtteranceDelay = 0

        synthesizer.speak(utterance)
        onEvent?(Event(
            type: "start",
            key: key,
            message: nil,
            voiceName: selectedVoice?.name,
            voiceLanguage: selectedVoice?.language,
            voiceQuality: selectedVoice.map { qualityLabel($0.quality) }
        ))
    }

    func pause() {
        synthesizer.pauseSpeaking(at: .word)
        onEvent?(Event(type: "pause", key: activeKey, message: nil))
    }

    func resume() {
        synthesizer.continueSpeaking()
        onEvent?(Event(type: "resume", key: activeKey, message: nil))
    }

    func stop() {
        let key = activeKey
        synthesizer.stopSpeaking(at: .immediate)
        activeKey = nil
        onEvent?(Event(type: "stop", key: key, message: nil))
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let key = activeKey
        activeKey = nil
        onEvent?(Event(type: "end", key: key, message: nil))
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let key = activeKey
        activeKey = nil
        onEvent?(Event(type: "stop", key: key, message: nil))
    }

    private func preferredVoice(language: String?) -> AVSpeechSynthesisVoice? {
        let normalized = normalizeLanguage(language)
        let voices = AVSpeechSynthesisVoice.speechVoices()
        let matching = voices.filter { $0.language == normalized }
        return matching.first { $0.quality == .premium }
            ?? matching.first { $0.quality == .enhanced }
            ?? matching.first
            ?? AVSpeechSynthesisVoice(language: normalized)
            ?? AVSpeechSynthesisVoice(language: "es-ES")
    }

    private func normalizeLanguage(_ language: String?) -> String {
        guard let language, !language.isEmpty else { return "es-ES" }
        let lowercased = language.replacingOccurrences(of: "_", with: "-").lowercased()
        if lowercased.hasPrefix("es") { return "es-ES" }
        return language
    }

    private func qualityLabel(_ quality: AVSpeechSynthesisVoiceQuality) -> String {
        switch quality {
        case .default:
            return "default"
        case .enhanced:
            return "enhanced"
        case .premium:
            return "premium"
        @unknown default:
            return "unknown"
        }
    }

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true)
        } catch {
            onEvent?(Event(type: "error", key: activeKey, message: error.localizedDescription))
        }
    }
}
