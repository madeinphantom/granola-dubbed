import Foundation
import WhisperKit
import OSLog

final class ASREngine {
    private let logger = Logger(subsystem: "app.atrium.infer", category: "ASREngine")
    var whisperKit: WhisperKit?
    
    init() {}
    
    func setup() async throws {
        // Loads model asynchronously. WhisperKit handles finding/downloading it.
        whisperKit = try await WhisperKit(model: "openai_whisper-large-v3-turbo")
    }
    
    func transcribe(audioURL: URL, progress: @escaping (Float) -> Void) async throws -> [TranscriptSegment] {
        guard let whisperKit = whisperKit else {
            try await setup()
            return try await transcribe(audioURL: audioURL, progress: progress)
        }
        
        logger.info("Starting transcription for \(audioURL.path)")
        
        // Load audio and decode with WhisperKit
        // Note: WhisperKit requires 16kHz mono. We assume the session m4a or mixed CAF is provided and WhisperKit's internal audio loader handles the resample.
        
        let result = try await whisperKit.transcribe(audioPath: audioURL.path) { progressInfo in
            progress(progressInfo.progress)
        }
        
        var segments: [TranscriptSegment] = []
        for resSegment in result?.segments ?? [] {
            let seg = TranscriptSegment(
                id: UUID(),
                speakerId: UUID(), // To be updated by Aligner
                start: TimeInterval(resSegment.start),
                end: TimeInterval(resSegment.end),
                text: resSegment.text,
                words: resSegment.words?.map { word in
                    TranscriptWord(start: TimeInterval(word.start), end: TimeInterval(word.end), text: word.word, probability: word.probability)
                } ?? [],
                isOverlap: false
            )
            segments.append(seg)
        }
        
        logger.info("Transcription completed with \(segments.count) segments.")
        return segments
    }
}
