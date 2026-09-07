import XCTest
@testable import Atrium

final class ExportServiceTests: XCTestCase {
    private let service = ExportService()
    private var speaker: Speaker!
    private var meeting: Meeting!

    override func setUp() {
        super.setUp()
        speaker = Speaker(id: UUID(), label: "Alice")
        meeting = Meeting(title: "Standup", duration: 125, notesMarkdown: "note body", speakers: [speaker])
    }

    private func document(speakerId: UUID) -> TranscriptDocument {
        let segment = TranscriptSegment(id: UUID(), speakerId: speakerId, start: 3661.5, end: 3665.0,
                                        text: "hello world", words: [], isOverlap: false)
        return TranscriptDocument(version: 1, language: "en", segments: [segment])
    }

    func testSRTUsesHourAwareCommaSeparatedTimestamps() {
        let srt = service.export(meeting: meeting, transcript: document(speakerId: speaker.id), format: .srt)
        XCTAssertTrue(srt.hasPrefix("1\n"))
        XCTAssertTrue(srt.contains("01:01:01,500 --> 01:01:05,000"))
    }

    func testMarkdownIncludesTitleNotesAndSpeakerLabel() {
        let md = service.export(meeting: meeting, transcript: document(speakerId: speaker.id), format: .markdown)
        XCTAssertTrue(md.contains("# Standup"))
        XCTAssertTrue(md.contains("**Alice**"))
        XCTAssertTrue(md.contains("note body"))
    }

    func testTextExportFormatsDurationAndSpeaker() {
        let txt = service.export(meeting: meeting, transcript: document(speakerId: speaker.id), format: .txt)
        XCTAssertTrue(txt.contains("Alice: hello world"))
        XCTAssertTrue(txt.contains("02:05"), "125s should render as 02:05")
    }

    func testJSONExportIsValid() {
        let json = service.export(meeting: meeting, transcript: document(speakerId: speaker.id), format: .json)
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(json.utf8)))
    }

    func testUnknownSpeakerFallsBackToUnknownLabel() {
        let txt = service.export(meeting: meeting, transcript: document(speakerId: UUID()), format: .txt)
        XCTAssertTrue(txt.contains("Unknown: hello world"))
    }

    func testNilTranscriptProducesEmptyPayloads() {
        XCTAssertEqual(service.export(meeting: meeting, transcript: nil, format: .json), "{}")
        XCTAssertTrue(service.export(meeting: meeting, transcript: nil, format: .srt).isEmpty)
    }
}
