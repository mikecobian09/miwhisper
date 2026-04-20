import AVFoundation
import Foundation

final class AudioRecorder: NSObject {
    private var recorder: AVAudioRecorder?
    private var currentFileURL: URL?

    func startRecording() throws -> URL {
        NSLog("[MiWhisper][Recorder] start requested")
        stopRecording(deleteCurrentFile: false)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("miwhisper-\(UUID().uuidString)")
            .appendingPathExtension("wav")

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
        ]

        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.isMeteringEnabled = false
        NSLog(
            "[MiWhisper][Recorder] configured path=%@ sampleRate=16000 channels=1 format=pcm16",
            url.path
        )

        guard recorder.prepareToRecord() else {
            NSLog("[MiWhisper][Recorder] prepareToRecord failed path=%@", url.path)
            try? FileManager.default.removeItem(at: url)
            throw RecorderError.failedToPrepare
        }

        self.recorder = recorder
        currentFileURL = url

        guard recorder.record() else {
            NSLog("[MiWhisper][Recorder] record() failed path=%@", url.path)
            stopRecording(deleteCurrentFile: true)
            throw RecorderError.failedToStart
        }

        NSLog("[MiWhisper][Recorder] recording started path=%@", url.path)

        return url
    }

    func stopRecording() {
        stopRecording(deleteCurrentFile: false)
    }

    private func stopRecording(deleteCurrentFile: Bool) {
        if let currentFileURL {
            let currentTime = recorder?.currentTime ?? 0
            NSLog(
                "[MiWhisper][Recorder] stop requested path=%@ currentTimeMs=%.1f delete=%@",
                currentFileURL.path,
                currentTime * 1000,
                deleteCurrentFile ? "true" : "false"
            )
        } else {
            NSLog("[MiWhisper][Recorder] stop requested without active file delete=%@", deleteCurrentFile ? "true" : "false")
        }

        recorder?.stop()
        recorder = nil

        if deleteCurrentFile, let currentFileURL {
            NSLog("[MiWhisper][Recorder] deleting partial file path=%@", currentFileURL.path)
            try? FileManager.default.removeItem(at: currentFileURL)
        }

        currentFileURL = nil
    }
}

enum RecorderError: LocalizedError {
    case failedToPrepare
    case failedToStart

    var errorDescription: String? {
        switch self {
        case .failedToPrepare:
            return "MiWhisper could not prepare the audio recorder."
        case .failedToStart:
            return "MiWhisper could not start recording."
        }
    }
}
