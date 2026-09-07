import Foundation

final class TranscriptAligner {
    func align(words: [TranscriptWord], speakerTurns: [(start: TimeInterval, end: TimeInterval, speakerId: UUID)]) -> [TranscriptSegment] {
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
