import XCTest
@testable import Atrium

final class TranscriptAlignerTests: XCTestCase {
    private let speakerA = UUID()
    private let speakerB = UUID()

    private func word(_ start: TimeInterval, _ end: TimeInterval, _ text: String) -> TranscriptWord {
        TranscriptWord(start: start, end: end, text: text, probability: 1.0)
    }

    private var turns: [(start: TimeInterval, end: TimeInterval, speakerId: UUID)] {
        [(start: 0.0, end: 1.0, speakerId: speakerA),
         (start: 1.0, end: 2.0, speakerId: speakerB)]
    }

    func testGroupsConsecutiveWordsBySpeaker() {
        let segments = TranscriptAligner().align(
            words: [word(0.0, 0.4, "hi"), word(0.5, 0.9, "there"), word(1.1, 1.5, "yes")],
            speakerTurns: turns
        )

        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments.first?.speakerId, speakerA)
        XCTAssertEqual(segments.first?.text, "hi there")
        XCTAssertEqual(segments.first?.end, 0.9, "Segment end should extend to the last word")
        XCTAssertEqual(segments.last?.speakerId, speakerB)
    }

    func testWordOutsideEverySpeakerTurnIsDropped() {
        let segments = TranscriptAligner().align(words: [word(9.0, 9.5, "lost")], speakerTurns: turns)
        XCTAssertTrue(segments.isEmpty)
    }

    func testEmptyInputs() {
        XCTAssertTrue(TranscriptAligner().align(words: [word(0, 1, "x")], speakerTurns: []).isEmpty)
        XCTAssertTrue(TranscriptAligner().align(words: [], speakerTurns: turns).isEmpty)
    }
}
