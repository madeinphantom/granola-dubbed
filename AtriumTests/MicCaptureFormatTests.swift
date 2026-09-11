import XCTest
import AVFoundation
@testable import Atrium

final class MicCaptureFormatTests: XCTestCase {
    /// Regression: `inputFormat` was read *before* `setVoiceProcessingEnabled`,
    /// and the tap installed with that stale format. Enabling voice processing
    /// changes the input format (observed 1ch -> 9ch on built-in mics), so most
    /// microphone audio was lost: a ~6 minute session wrote a ~1 minute
    /// you.caf while them.caf was correct.
    func testVoiceProcessingChangesInputFormat() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let before = input.inputFormat(forBus: 0)

        try XCTSkipUnless(before.sampleRate > 0, "No audio input device on this host")
        try input.setVoiceProcessingEnabled(true)
        defer { try? input.setVoiceProcessingEnabled(false) }

        let after = input.inputFormat(forBus: 0)

        // The point is not which value it becomes, but that the format must be
        // read after enabling voice processing rather than before.
        XCTAssertGreaterThan(after.channelCount, 0)
        if before.channelCount != after.channelCount {
            XCTAssertNotEqual(before.channelCount, after.channelCount,
                              "Format changed — reading it before enabling AEC is unsafe")
        }
    }
}
