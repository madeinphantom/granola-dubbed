import XCTest
@testable import Atrium

final class TrackMergeTests: XCTestCase {
    private let you = UUID()
    private let them = UUID()

    private func seg(_ start: TimeInterval, _ end: TimeInterval, _ text: String) -> TranscriptSegment {
        TranscriptSegment(id: UUID(), speakerId: UUID(), start: start, end: end,
                          text: text, words: [], isOverlap: false)
    }

    func testSpeakerComesFromTheTrack() {
        let merged = TranscriptAligner.mergeTracks(
            local: [seg(0, 1, "Hi, can you hear me?")], localSpeaker: you,
            remote: [seg(1.5, 3, "Yes, loud and clear.")], remoteSpeaker: them)
        XCTAssertEqual(merged.map(\.speakerId), [you, them])
    }

    func testSegmentsAreInterleavedByTime() {
        let merged = TranscriptAligner.mergeTracks(
            local: [seg(0, 1, "one"), seg(4, 5, "three")], localSpeaker: you,
            remote: [seg(2, 3, "two")], remoteSpeaker: them)
        XCTAssertEqual(merged.map(\.text), ["one", "two", "three"])
    }

    func testMicBleedOfRemoteSpeechIsDropped() {
        let merged = TranscriptAligner.mergeTracks(
            local: [seg(0.1, 2.9, "the quick brown fox")], localSpeaker: you,
            remote: [seg(0, 3, "The quick brown fox jumps.")], remoteSpeaker: them)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.speakerId, them)
    }

    func testOverlappingButDifferentSpeechIsKept() {
        let merged = TranscriptAligner.mergeTracks(
            local: [seg(0, 2, "sorry, go ahead")], localSpeaker: you,
            remote: [seg(0.5, 3, "I was going to say")], remoteSpeaker: them)
        XCTAssertEqual(merged.count, 2)
    }

    func testEmptySegmentsAreRemoved() {
        let merged = TranscriptAligner.mergeTracks(
            local: [seg(0, 1, "  ")], localSpeaker: you,
            remote: [seg(1, 2, "")], remoteSpeaker: them)
        XCTAssertTrue(merged.isEmpty)
    }
}
