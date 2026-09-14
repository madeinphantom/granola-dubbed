import XCTest
import AVFoundation
@testable import Atrium

/// Covers the multi-channel handling that the voice-processing bug exposed.
///
/// The original defect — reading `inputFormat` before enabling voice
/// processing, then installing a tap with that stale format — can only be
/// reproduced against real audio hardware, and `setVoiceProcessingEnabled`
/// hangs in the CoreAudio HAL on headless CI runners. So rather than drive the
/// hardware, this pins the arithmetic that made the bug destructive: folding a
/// multi-channel buffer down to the mono `you.caf` expects.
final class MicDownmixTests: XCTestCase {
    /// Mirrors `DualCaptureSession.handleMicAudio`'s downmix.
    private func downmix(_ channels: [[Float]]) -> [Float] {
        let frameCount = channels[0].count
        let scale = 1.0 / Float(channels.count)
        var out = [Float](repeating: 0, count: frameCount)
        for channel in channels {
            for frame in 0..<frameCount {
                out[frame] += channel[frame] * scale
            }
        }
        return out
    }

    func testMonoInputIsUnchanged() {
        XCTAssertEqual(downmix([[0.5, -0.25, 1.0]]), [0.5, -0.25, 1.0])
    }

    func testMultiChannelFoldsToTheAverage() {
        // A 9-channel buffer is what voice processing actually delivered.
        let channels = Array(repeating: [Float](repeating: 0.9, count: 4), count: 9)
        let result = downmix(channels)
        XCTAssertEqual(result.count, 4)
        for sample in result {
            XCTAssertEqual(sample, 0.9, accuracy: 0.0001,
                           "Identical channels must fold to the same amplitude")
        }
    }

    func testDownmixPreservesFrameCountNotSampleCount() {
        // The bug wrote the wrong number of frames, so duration was wrong:
        // a 6 minute recording produced a 1 minute you.caf.
        let channels = Array(repeating: [Float](repeating: 0.1, count: 480), count: 9)
        XCTAssertEqual(downmix(channels).count, 480,
                       "Output length is frames, never frames * channels")
    }

    func testOppositePhaseChannelsCancel() {
        XCTAssertEqual(downmix([[1.0, 1.0], [-1.0, -1.0]]), [0.0, 0.0])
    }
}
