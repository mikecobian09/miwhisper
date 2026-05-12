import AVFoundation
import Speech

@MainActor
final class NativeCarCommandListener: NSObject, ObservableObject {
    struct Event {
        let type: String
        let state: String
        let message: String
        let transcript: String
        let prompt: String
        let armed: Bool

        var dictionary: [String: Any] {
            [
                "type": type,
                "state": state,
                "message": message,
                "transcript": transcript,
                "prompt": prompt,
                "armed": armed,
            ]
        }
    }

    private enum Mode {
        case idle
        case waitingForWake
        case dictating
        case pausedAfterPrompt
    }

    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "es-ES"))
    private var audioEngine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var silenceTask: Task<Void, Never>?
    private var restartTask: Task<Void, Never>?
    private var mode: Mode = .idle
    private var armed = false
    private var isStopping = false
    private var silenceSeconds = 2.0
    private var currentCommand = ""
    private var lastCommandChangeAt: Date?
    private var lastHeardTranscript = ""
    private var wakeBeepPlayer: AVAudioPlayer?
    private var submitBeepPlayer: AVAudioPlayer?

    var onEvent: ((Event) -> Void)?

    func arm(silenceSeconds: Double = 2.0) {
        self.silenceSeconds = max(1.2, min(silenceSeconds, 4.0))
        armed = true
        if recognitionTask != nil || audioEngine?.isRunning == true {
            emit(type: "armed", state: "listening", message: "Di oye Codex para dictar.")
            return
        }

        Task {
            await startListening()
        }
    }

    func disarm() {
        armed = false
        currentCommand = ""
        lastCommandChangeAt = nil
        lastHeardTranscript = ""
        stopRecognition(keepArmed: false)
        emit(type: "stopped", state: "off", message: "Modo coche armado desactivado.")
    }

    private func startListening() async {
        guard armed else { return }
        guard speechRecognizer?.isAvailable == true else {
            emit(type: "error", state: "error", message: "El reconocimiento de voz de iOS no está disponible ahora.")
            return
        }
        guard await requestSpeechAuthorization() else {
            emit(type: "error", state: "error", message: "Activa el permiso de reconocimiento de voz para MiWhisper.")
            return
        }
        guard await requestRecordPermission() else {
            emit(type: "error", state: "error", message: "Activa el permiso de micrófono para MiWhisper.")
            return
        }

        do {
            try configureAudioSession()
            try beginRecognition()
            mode = .waitingForWake
            emit(type: "armed", state: "listening", message: "Di oye Codex para dictar.")
        } catch {
            stopRecognition(keepArmed: true)
            emit(type: "error", state: "error", message: error.localizedDescription)
            scheduleRestart()
        }
    }

    private func beginRecognition() throws {
        stopRecognition(keepArmed: true)
        isStopping = false
        currentCommand = ""
        lastCommandChangeAt = nil
        lastHeardTranscript = ""

        let audioEngine = AVAudioEngine()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = false

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }

        recognitionRequest = request
        self.audioEngine = audioEngine

        recognitionTask = speechRecognizer?.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                self?.handleRecognition(result: result, error: error)
            }
        }

        audioEngine.prepare()
        try audioEngine.start()
        startSilenceLoop()
    }

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .spokenAudio,
            options: [.allowBluetoothHFP, .defaultToSpeaker, .duckOthers]
        )
        try session.setActive(true, options: .notifyOthersOnDeactivation)
    }

    private func handleRecognition(result: SFSpeechRecognitionResult?, error: Error?) {
        if let result {
            handleTranscript(result.bestTranscription.formattedString)
        }

        if result?.isFinal == true || error != nil {
            guard armed, !isStopping, mode != .pausedAfterPrompt else { return }
            scheduleRestart()
        }
    }

    private func handleTranscript(_ transcript: String) {
        guard armed else { return }

        switch mode {
        case .waitingForWake:
            guard let command = commandAfterWakeWord(in: transcript) else {
                emitHearingIfNeeded(transcript)
                return
            }
            mode = .dictating
            currentCommand = cleanCommand(command)
            if !currentCommand.isEmpty {
                lastCommandChangeAt = Date()
            }
            playWakeBeep()
            emit(
                type: "wake",
                state: "dictating",
                message: currentCommand.isEmpty ? "Te escucho." : "Dictando.",
                transcript: currentCommand
            )
        case .dictating:
            let command = commandAfterWakeWord(in: transcript) ?? transcript
            let clean = cleanCommand(command)
            if clean != currentCommand {
                currentCommand = clean
                if !clean.isEmpty {
                    lastCommandChangeAt = Date()
                }
                emit(type: "transcript", state: "dictating", message: "Dictando.", transcript: clean)
            }
        case .idle, .pausedAfterPrompt:
            break
        }
    }

    private func startSilenceLoop() {
        silenceTask?.cancel()
        silenceTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                self?.finishIfSilent()
            }
        }
    }

    private func finishIfSilent() {
        guard armed, mode == .dictating, !currentCommand.isEmpty, let lastCommandChangeAt else { return }
        guard Date().timeIntervalSince(lastCommandChangeAt) >= silenceSeconds else { return }

        let prompt = currentCommand
        mode = .pausedAfterPrompt
        playSubmitBeep()
        stopRecognition(keepArmed: true)
        emit(type: "prompt", state: "submitted", message: "Enviando prompt.", transcript: prompt, prompt: prompt)
    }

    private func scheduleRestart() {
        restartTask?.cancel()
        restartTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 650_000_000)
            await self?.startListening()
        }
    }

    private func stopRecognition(keepArmed: Bool) {
        isStopping = true
        restartTask?.cancel()
        restartTask = nil
        silenceTask?.cancel()
        silenceTask = nil

        if audioEngine?.isRunning == true {
            audioEngine?.stop()
        }
        audioEngine?.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        audioEngine = nil

        if !keepArmed {
            mode = .idle
            armed = false
        }
    }

    private func requestSpeechAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    private func requestRecordPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            if #available(iOS 17.0, *) {
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            } else {
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    private func commandAfterWakeWord(in transcript: String) -> String? {
        let normalized = normalize(transcript)
        let words = normalized.split(separator: " ").map(String.init)
        guard let codexIndex = wakeWordIndex(in: words) else {
            return nil
        }
        let commandWords = words.dropFirst(codexIndex + 1)
        return commandWords.joined(separator: " ")
    }

    private func wakeWordIndex(in words: [String]) -> Int? {
        for (index, word) in words.enumerated() {
            if isStrongWakeWord(word) {
                return index
            }

            let previous = index > 0 ? words[index - 1] : nil
            if isFallbackWakeWord(word, previous: previous) {
                return index
            }
        }
        return nil
    }

    private func isStrongWakeWord(_ word: String) -> Bool {
        let compact = word.replacingOccurrences(of: " ", with: "")
        return [
            "codex",
            "kodex",
            "kodeks",
            "kodec",
            "codec",
            "codecs",
            "codexs",
            "kodexs",
            "oyecodex",
            "oyekodex",
            "oyekodeks",
            "heycodex",
            "heykodex",
            "okcodex",
            "okkodex",
        ].contains(compact)
    }

    private func isFallbackWakeWord(_ word: String, previous: String?) -> Bool {
        guard previous == "oye" || previous == "hey" || previous == "ok" else { return false }
        if ["codigo", "codic", "codex", "kodex", "kodeks", "kodec"].contains(word) {
            return true
        }
        return (word.hasPrefix("cod") || word.hasPrefix("kod")) && (4...8).contains(word.count)
    }

    private func emitHearingIfNeeded(_ transcript: String) {
        let clean = cleanCommand(transcript)
        guard clean.count >= 3, clean != lastHeardTranscript else { return }
        lastHeardTranscript = clean
        emit(type: "hearing", state: "listening", message: "He oído: \(clean)", transcript: clean)
    }

    private func playWakeBeep() {
        playBeep(frequency: 880, duration: 0.14, isWake: true)
    }

    private func playSubmitBeep() {
        playBeep(frequency: 520, duration: 0.18, isWake: false)
    }

    private func playBeep(frequency: Double, duration: Double, isWake: Bool) {
        do {
            let player = try AVAudioPlayer(data: makeBeepWavData(frequency: frequency, duration: duration))
            player.volume = 1.0
            player.prepareToPlay()
            player.play()
            if isWake {
                wakeBeepPlayer = player
            } else {
                submitBeepPlayer = player
            }
        } catch {
            emit(type: "audio-warning", state: modeStateName, message: "No he podido reproducir el beep.")
        }
    }

    private var modeStateName: String {
        switch mode {
        case .idle:
            return "off"
        case .waitingForWake:
            return "listening"
        case .dictating:
            return "dictating"
        case .pausedAfterPrompt:
            return "submitted"
        }
    }

    private func makeBeepWavData(frequency: Double, duration: Double) -> Data {
        let sampleRate = 44_100
        let sampleCount = max(1, Int(Double(sampleRate) * duration))
        let bytesPerSample = 2
        let dataByteCount = sampleCount * bytesPerSample
        var data = Data()

        data.append(contentsOf: Array("RIFF".utf8))
        data.appendUInt32LE(UInt32(36 + dataByteCount))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        data.appendUInt32LE(16)
        data.appendUInt16LE(1)
        data.appendUInt16LE(1)
        data.appendUInt32LE(UInt32(sampleRate))
        data.appendUInt32LE(UInt32(sampleRate * bytesPerSample))
        data.appendUInt16LE(UInt16(bytesPerSample))
        data.appendUInt16LE(16)
        data.append(contentsOf: Array("data".utf8))
        data.appendUInt32LE(UInt32(dataByteCount))

        for sampleIndex in 0..<sampleCount {
            let progress = Double(sampleIndex) / Double(sampleCount)
            let fadeIn = min(1.0, progress / 0.12)
            let fadeOut = min(1.0, (1.0 - progress) / 0.18)
            let envelope = min(fadeIn, fadeOut)
            let value = sin(2.0 * .pi * frequency * Double(sampleIndex) / Double(sampleRate))
            let sample = Int16(value * envelope * 24_000)
            data.appendInt16LE(sample)
        }

        return data
    }

    private func cleanCommand(_ command: String) -> String {
        command
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalize(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "es_ES"))
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9áéíóúñü]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func emit(
        type: String,
        state: String,
        message: String,
        transcript: String = "",
        prompt: String = ""
    ) {
        onEvent?(Event(
            type: type,
            state: state,
            message: message,
            transcript: transcript,
            prompt: prompt,
            armed: armed
        ))
    }
}

private extension Data {
    mutating func appendUInt16LE(_ value: UInt16) {
        append(UInt8(value & 0xff))
        append(UInt8((value >> 8) & 0xff))
    }

    mutating func appendInt16LE(_ value: Int16) {
        appendUInt16LE(UInt16(bitPattern: value))
    }

    mutating func appendUInt32LE(_ value: UInt32) {
        append(UInt8(value & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 24) & 0xff))
    }
}
