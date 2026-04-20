import Foundation

final class WhisperTranscriber {
    private let bridge = WhisperBridge()

    func transcribe(
        audioFileURL: URL,
        cliPath _: String,
        modelPath: String,
        language: String,
        mode: TranscriptionMode
    ) async throws -> String {
        guard FileManager.default.fileExists(atPath: modelPath) else {
            throw WhisperError.missingModel(modelPath)
        }

        return try await Task.detached(priority: .userInitiated) { [bridge] in
            let attemptLanguages = Self.transcriptionLanguageAttempts(
                requestedLanguage: language,
                mode: mode
            )
            NSLog(
                "[MiWhisper][Transcriber] start audio=%@ model=%@ requestedLanguage=%@ mode=%@ attempts=%@",
                audioFileURL.path,
                URL(fileURLWithPath: modelPath).lastPathComponent,
                language,
                mode.rawValue,
                attemptLanguages.joined(separator: ",")
            )
            var lastError: Error?

            for attemptLanguage in attemptLanguages {
                do {
                    NSLog(
                        "[MiWhisper][Transcriber] attempting language=%@ translate=%@",
                        attemptLanguage,
                        mode == .translateToEnglish ? "true" : "false"
                    )
                    let transcript = try bridge.transcribeAudio(
                        atPath: audioFileURL.path,
                        modelPath: modelPath,
                        language: attemptLanguage,
                        translateToEnglish: mode == .translateToEnglish
                    )
                    NSLog(
                        "[MiWhisper][Transcriber] success language=%@ transcriptChars=%ld",
                        attemptLanguage,
                        transcript.count
                    )
                    return transcript
                } catch {
                    lastError = error
                    let nsError = error as NSError
                    NSLog(
                        "[MiWhisper][Transcriber] failure language=%@ domain=%@ code=%ld description=%@",
                        attemptLanguage,
                        nsError.domain,
                        nsError.code,
                        nsError.localizedDescription
                    )

                    guard Self.isEmptyTranscriptError(error) else {
                        throw error
                    }
                }
            }

            if let lastError {
                let nsError = lastError as NSError
                NSLog(
                    "[MiWhisper][Transcriber] exhausted attempts domain=%@ code=%ld description=%@",
                    nsError.domain,
                    nsError.code,
                    nsError.localizedDescription
                )
            }
            throw lastError ?? WhisperError.emptyTranscript
        }.value
    }

    private static func transcriptionLanguageAttempts(
        requestedLanguage: String,
        mode: TranscriptionMode
    ) -> [String] {
        let normalizedRequested = normalizeLanguageCode(requestedLanguage)

        guard normalizedRequested == "auto" else {
            return [normalizedRequested]
        }

        switch mode {
        case .literal:
            return ["auto"]
        case .translateToEnglish:
            return ["auto", "en"]
        }
    }

    private static func normalizeLanguageCode(_ language: String) -> String {
        let trimmed = language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return "auto" }
        if trimmed == "auto" { return "auto" }

        return trimmed
            .split(whereSeparator: { $0 == "-" || $0 == "_" })
            .first
            .map(String.init) ?? trimmed
    }

    private static func isEmptyTranscriptError(_ error: Error) -> Bool {
        if let whisperError = error as? WhisperError, whisperError == .emptyTranscript {
            return true
        }

        let nsError = error as NSError
        return nsError.domain == "MiWhisper.WhisperBridge" && nsError.code == 23
    }
}

enum WhisperError: LocalizedError, Equatable {
    case missingModel(String)
    case emptyTranscript
    case runtimeFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingModel(let path):
            return "Missing Whisper model at \(path). Run scripts/bootstrap-whispercpp.sh first or download another model into /models."
        case .emptyTranscript:
            return "The transcript came back empty."
        case .runtimeFailed(let message):
            return "Embedded whisper.cpp failed: \(message)"
        }
    }
}
