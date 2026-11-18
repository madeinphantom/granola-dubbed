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

    /// Transcribes each stretch of speech in the track on its own.
    ///
    /// Decoding a whole track as one long stream was unreliable on real calls:
    /// Whisper judged the quiet microphone to be "no speech" and skipped whole
    /// windows, and one bad guess shifted every window after it, so the same
    /// audio gave different transcripts run to run. Short, separate stretches
    /// keep a bad guess to that stretch.
    public func transcribe(_ url: URL, speaker: Speaker,
                           progress: @escaping @Sendable (Double) -> Void) async throws -> [Utterance] {
        guard let whisper else { throw CocoaError(.featureUnsupported) }
        let samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: url.path)
        let regions = SpeechRegions.find(in: samples, sampleRate: WhisperKit.sampleRate)
        var options = DecodingOptions(skipSpecialTokens: true, wordTimestamps: true,
                                      chunkingStrategy: ChunkingStrategy.none)
        // Each stretch is already known to hold sound; let Whisper decide
        // what was said rather than skip it as silence.
        options.noSpeechThreshold = nil

        var utterances: [Utterance] = []
        let batchSize = 16
        for batchStart in stride(from: 0, to: regions.count, by: batchSize) {
            let batch = Array(regions[batchStart..<min(batchStart + batchSize, regions.count)])
            let results = await whisper.transcribeWithResults(
                audioArrays: batch.map { Array(samples[$0]) }, decodeOptions: options)
            for (region, result) in zip(batch, results) {
                let offset = Double(region.lowerBound) / Double(WhisperKit.sampleRate)
                for segment in try result.get().flatMap(\.segments) {
                    let text = Self.clean(segment.text)
                    guard !text.isEmpty else { continue }
                    // Whisper retries at a higher temperature only when its
                    // confident pass failed. On ringtones and line noise that
                    // retry is where "you" and "Thank you." come from.
                    guard segment.temperature == 0 else {
                        logger.info("Dropped a guessed segment at \(offset + Double(segment.start))s")
                        continue
                    }
                    let words = (segment.words ?? []).compactMap { word -> Word? in
                        let text = Self.clean(word.word)
                        return text.isEmpty ? nil : Word(text: text, start: offset + Double(word.start),
                                                          end: offset + Double(word.end),
                                                          probability: Double(word.probability))
                    }
                    guard !Self.isStockPhrase(text, words: words) else {
                        logger.info("Dropped a stock phrase at \(offset + Double(segment.start))s")
                        continue
                    }
                    utterances.append(Utterance(speaker: speaker, start: offset + Double(segment.start),
                                                end: offset + Double(segment.end), text: text, words: words))
                }
            }
            progress(Double(min(batchStart + batchSize, regions.count)) / Double(max(regions.count, 1)))
        }
        return utterances
    }

    /// What Whisper writes over noise it cannot place, learned from subtitles.
    static let stockPhrases: Set = ["thank you", "thanks", "you", "bye", "thank you very much",
                                    "thanks for watching", "thank you for watching"]

    /// A stock phrase Whisper is unsure of is noise, not speech. Said clearly,
    /// "thank you" decodes with high confidence and is kept.
    static func isStockPhrase(_ text: String, words: [Word]) -> Bool {
        let phrase = TranscriptMerger.tokens(text).joined(separator: " ")
        guard stockPhrases.contains(phrase) else { return false }
        return (words.map(\.probability).min() ?? 0) < 0.5
    }

    /// Whisper can still emit special tokens (`<|en|>`, `<|0.00|>`) inline,
    /// and labels sounds instead of words (`*phone ringing*`, `[Music]`).
    static func clean(_ raw: String) -> String {
        raw.replacingOccurrences(of: "<\\|[^|]*\\|>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\*[^*]*\\*|\\[[^\\]]*\\]|\\([^)]*\\)", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Where a track has sound worth transcribing.
enum SpeechRegions {
    static let frameSeconds = 0.1
    /// Sound this far above the track's own background counts. Relative, not
    /// absolute: voice processing leaves the microphone far quieter than the
    /// call's audio, and a fixed level missed the user's whole side.
    static let aboveBackgroundDB: Float = 12
    /// Never count anything quieter than this, whatever the background.
    static let minimumDB: Float = -50
    /// Always count anything louder than this. The background is the
    /// quietest tenth of the track, which is speech itself when one person
    /// talks almost without pause.
    static let alwaysDB: Float = -35
    /// Pauses shorter than this stay inside one stretch.
    static let joinGapSeconds = 0.6
    static let minimumSeconds = 0.3
    /// Under Whisper's 30 s window, so a stretch is decoded in one pass.
    static let maximumSeconds = 28.0
    static let padBeforeSeconds = 0.3
    static let padAfterSeconds = 0.4

    static func find(in samples: [Float], sampleRate: Int) -> [Range<Int>] {
        let frame = Int(Double(sampleRate) * frameSeconds)
        guard frame > 0, samples.count >= frame else { return [] }
        let levels = stride(from: 0, to: samples.count - frame + 1, by: frame).map { start -> Float in
            var sum: Float = 0
            for i in start..<(start + frame) { sum += samples[i] * samples[i] }
            return 10 * log10(max(sum / Float(frame), 1e-12))
        }
        let background = levels.sorted()[levels.count / 10]
        let threshold = min(max(background + aboveBackgroundDB, minimumDB), alwaysDB)
        let loud = levels.map { $0 > threshold }

        let joinGap = Int(joinGapSeconds / frameSeconds), longest = Int(maximumSeconds / frameSeconds)
        var frames: [Range<Int>] = []
        var index = 0
        while index < loud.count {
            guard loud[index] else { index += 1; continue }
            let first = index
            var last = index, cursor = index + 1
            while cursor < loud.count, cursor - last <= joinGap, cursor - first < longest {
                if loud[cursor] { last = cursor }
                cursor += 1
            }
            frames.append(first..<(last + 1))
            index = last + 1
        }
        let before = Int(padBeforeSeconds * Double(sampleRate)), after = Int(padAfterSeconds * Double(sampleRate))
        return frames
            .filter { Double($0.count) * frameSeconds >= minimumSeconds }
            .map { max(0, $0.lowerBound * frame - before)..<min(samples.count, $0.upperBound * frame + after) }
    }
}
