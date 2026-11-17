import AVFoundation
import Foundation
import OSLog
import WhisperKit

/// Speech recognition with WhisperKit, run on one track at a time.
public final class SpeechRecognizer: @unchecked Sendable {
    /// A directory in argmaxinc/whisperkit-coreml. An explicit name is used
    /// verbatim as a download path, so it must match exactly (note the
    /// underscore before `turbo`). Override with
    /// `defaults write app.atrium.mac WhisperModel openai_whisper-small`.
    public static let defaultModel = "openai_whisper-large-v3_turbo"

    public static var configuredModel: String {
        UserDefaults.standard.string(forKey: "WhisperModel").flatMap { $0.isEmpty ? nil : $0 } ?? defaultModel
    }

    /// Segments quieter than this (RMS, full scale 1.0) are treated as
    /// silence. Whisper invents text for silent audio ("Thank you.", "You"),
    /// and each track is silent whenever the other person talks.
    static let silenceRMS: Float = 0.001

    private let logger = Logger(subsystem: "app.atrium", category: "SpeechRecognizer")
    private var whisper: WhisperKit?
    private var loadedModel: String?

    public init() {}

    /// Loads the model, downloading it on first use.
    public func load(model: String) async throws {
        if loadedModel == model, whisper != nil { return }
        whisper = nil
        logger.info("Loading \(model, privacy: .public)")
        whisper = try await WhisperKit(model: model, verbose: false, logLevel: .error)
        loadedModel = model
    }

    /// Frees the model's memory between calls.
    public func unload() {
        whisper = nil
        loadedModel = nil
    }

    public func transcribe(_ url: URL, speaker: Speaker,
                           progress: @escaping @Sendable (Double) -> Void) async throws -> [Utterance] {
        guard let whisper else { throw CocoaError(.featureUnsupported) }
        let options = DecodingOptions(
            skipSpecialTokens: true,
            wordTimestamps: true,
            // Split on voice activity: skips the long silences in a one-sided
            // track and lets windows decode in parallel.
            chunkingStrategy: .vad)

        var windows = 0
        let results: [TranscriptionResult] = try await whisper.transcribe(
            audioPath: url.path, decodeOptions: options
        ) { _ in
            windows += 1
            // WhisperKit reports no total, so approach 1 without claiming a percentage.
            progress(1 - 1 / Double(windows + 1))
            return true
        }

        let reader = try? AVAudioFile(forReading: url)
        var utterances: [Utterance] = []
        for segment in results.flatMap(\.segments) {
            let text = Self.clean(segment.text)
            guard !text.isEmpty else { continue }
            let start = Double(segment.start), end = Double(segment.end)
            if let reader, let rms = Self.rms(of: reader, from: start, to: end), rms < Self.silenceRMS {
                logger.info("Dropped \"\(text, privacy: .private)\" over silence (rms \(rms))")
                continue
            }
            let words = (segment.words ?? []).compactMap { word -> Word? in
                let text = Self.clean(word.word)
                return text.isEmpty ? nil : Word(text: text, start: Double(word.start),
                                                  end: Double(word.end), probability: Double(word.probability))
            }
            utterances.append(Utterance(speaker: speaker, start: start, end: end, text: text, words: words))
        }
        return utterances
    }

    /// Whisper can still emit special tokens (`<|en|>`, `<|0.00|>`) inline.
    static func clean(_ raw: String) -> String {
        raw.replacingOccurrences(of: "<\\|[^|]*\\|>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// RMS of the file between two times, reading only that span.
    static func rms(of file: AVAudioFile, from start: Double, to end: Double) -> Float? {
        let rate = file.processingFormat.sampleRate
        let first = max(0, AVAudioFramePosition(start * rate))
        let last = min(file.length, AVAudioFramePosition(end * rate))
        guard last > first,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: AVAudioFrameCount(last - first)) else { return nil }
        file.framePosition = first
        guard (try? file.read(into: buffer, frameCount: AVAudioFrameCount(last - first))) != nil,
              let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return nil }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += samples[i] * samples[i] }
        return (sum / Float(buffer.frameLength)).squareRoot()
    }
}

