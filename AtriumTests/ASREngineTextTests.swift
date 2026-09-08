import XCTest
@testable import Atrium

final class ASREngineTextTests: XCTestCase {
    func testStripsWhisperSpecialTokens() {
        // Verified against real WhisperKit output for large-v3_turbo.
        let raw = "<|startoftranscript|><|en|><|transcribe|><|0.00|> Hello, this is a test.<|2.68|>"
        XCTAssertEqual(ASREngine.cleanText(raw), "Hello, this is a test.")
    }

    func testLeavesOrdinaryTextAndPunctuationIntact() {
        XCTAssertEqual(ASREngine.cleanText("Speaker attribution should work correctly."),
                       "Speaker attribution should work correctly.")
    }

    func testTrimsLeadingWhitespaceOnWordTokens() {
        XCTAssertEqual(ASREngine.cleanText(" Hello,"), "Hello,")
    }

    func testHandlesEmptyAndTokenOnlyInput() {
        XCTAssertEqual(ASREngine.cleanText(""), "")
        XCTAssertEqual(ASREngine.cleanText("<|endoftext|>"), "")
    }
}
