import Foundation

final class TranscriptAligner {
    /// Assigns each word to the speaker turn it overlaps most.
    ///
    /// Words that overlap no turn are attributed to `fallbackSpeakerId` (or the
    /// nearest preceding turn) rather than discarded — dropping them would
    /// silently produce an empty transcript whenever speaker detection fails,
    /// losing a whole meeting's words.
    func align(words: [TranscriptWord],
               speakerTurns: [(start: TimeInterval, end: TimeInterval, speakerId: UUID)],
               fallbackSpeakerId: UUID? = nil) -> [TranscriptSegment] {
        var segments: [TranscriptSegment] = []
        
        // Simple logic: assign word to speaker with most overlap
        for word in words {
            var bestSpeaker: UUID?
            var maxOverlap: TimeInterval = 0
            
            for turn in speakerTurns {
                let overlapStart = max(word.start, turn.start)
                let overlapEnd = min(word.end, turn.end)
                if overlapEnd > overlapStart {
                    let overlap = overlapEnd - overlapStart
                    if overlap > maxOverlap {
                        maxOverlap = overlap
                        bestSpeaker = turn.speakerId
                    }
                }
            }
            
            // Never drop a transcribed word: fall back to the most recent
            // speaker, then to the caller's fallback, then to any known turn.
            if bestSpeaker == nil {
                bestSpeaker = segments.last?.speakerId
                    ?? fallbackSpeakerId
                    ?? speakerTurns.first?.speakerId
            }

            if let bestSpeaker = bestSpeaker {
                if segments.last?.speakerId == bestSpeaker {
                    segments[segments.count - 1].words.append(word)
                    segments[segments.count - 1].end = word.end
                    segments[segments.count - 1].text += " " + word.text
                } else {
                    let newSeg = TranscriptSegment(id: UUID(), speakerId: bestSpeaker, start: word.start, end: word.end, text: word.text, words: [word], isOverlap: false)
                    segments.append(newSeg)
                }
            }
        }
        
        return segments
    }
}
