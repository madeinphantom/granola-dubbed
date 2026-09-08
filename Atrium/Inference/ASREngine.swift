import Foundation
import WhisperKit
import OSLog

final class ASREngine {
    private let logger = Logger(subsystem: "app.atrium.infer", category: "ASREngine")
    var whisperKit: WhisperKit?
    
    init() {}
    
    /// Model variant on argmaxinc/whisperkit-coreml. An explicit name is used
    /// verbatim as a download path with no validation or fallback, so it must
    /// match a directory that actually exists in that repo — note the
    /// underscore before `turbo`.
    static let modelVariant = "openai_whisper-large-v3_turbo"

    func setup() async throws {
        // Loads model asynchronously. WhisperKit handles finding/downloading it.
        whisperKit = try await WhisperKit(model: Self.modelVariant)
    }
    
    func transcribe(audioURL: URL, progress: @escaping (Float) -> Void) async throws -> [TranscriptSegment] {
        guard let whisperKit = whisperKit else {
            try await setup()
            return try await transcribe(audioURL: audioURL, progress: progress)
        }
        
        logger.info("Starting transcription for \(audioURL.path)")
        
        // Load audio and decode with WhisperKit
        // Note: WhisperKit requires 16kHz mono. We assume the session m4a or mixed CAF is provided and WhisperKit's internal audio loader handles the resample.
        
        // wordTimestamps defaults to false. Without it every segment's `words`
        // is nil, the aligner receives no words, and every meeting produces an
        // empty transcript — so it must be requested explicitly.
        let options = DecodingOptions(wordTimestamps: true)

        // WhisperKit reports no completion percentage, only per-window updates.
        // Returning true continues transcription; returning false cancels it.
        var windowsSeen = 0
        let results: [TranscriptionResult] = try await whisperKit.transcribe(
            audioPath: audioURL.path,
            decodeOptions: options
        ) { _ in
            windowsSeen += 1
            // No total window count is available, so approach 1.0 asymptotically
            // rather than reporting a percentage we cannot actually compute.
            progress(1.0 - 1.0 / Float(windowsSeen + 1))
            return true
        }
        
        var segments: [TranscriptSegment] = []
        // Chunked audio yields several results; concatenate all their segments.
        for resSegment in results.flatMap(\.segments) {
            let seg = TranscriptSegment(
                id: UUID(),
                speakerId: UUID(), // To be updated by Aligner
                start: TimeInterval(resSegment.start),
                end: TimeInterval(resSegment.end),
                text: Self.cleanText(resSegment.text),
                words: resSegment.words?.map { word in
                    TranscriptWord(start: TimeInterval(word.start),
                                   end: TimeInterval(word.end),
                                   text: Self.cleanText(word.word),
                                   probability: word.probability)
                } ?? [],
                isOverlap: false
            )
            segments.append(seg)
        }
        
        if segments.allSatisfy({ $0.words.isEmpty }) && !segments.isEmpty {
            logger.error("Transcription produced segments but no word timings; speaker alignment will be degraded.")
        }
        logger.info("Transcription completed with \(segments.count) segments.")
        return segments
    }

    /// Whisper emits special tokens inline (`<|startoftranscript|>`, `<|en|>`,
    /// `<|0.00|>` …). They must never reach the transcript or exports.
    static func cleanText(_ raw: String) -> String {
        raw.replacingOccurrences(of: "<\\|[^|]*\\|>",
                                 with: "",
                                 options: .regularExpression)
           .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
