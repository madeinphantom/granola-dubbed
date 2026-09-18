import XCTest
import AVFoundation
@testable import Atrium

/// Covers the ring-buffer contract the writer's drain loop depends on.
final class SessionWriterDrainTests: XCTestCase {
    private let chunk = 2400

    func testDrainingUntilEmptyKeepsUpWithAJitteryProducer() {
        // `Task.sleep` guarantees only a minimum delay, so poll ticks run late
        // and several chunks accumulate. Draining one fixed chunk per tick
        // could never catch up and the backlog grew until audio was discarded.
        let buffer = AudioRingBuffer(capacityFrames: 48000 * 10, channels: 1)
        var produced = 0
        var drained = 0

        for tick in 0..<200 {
            for _ in 0..<((tick % 10 == 0) ? 3 : 1) {
                buffer.write(data: [Float](repeating: 1.0, count: chunk), count: chunk)
                produced += chunk
            }
            while buffer.availableFrames >= chunk, let got = buffer.read(count: chunk) {
                drained += got.count
            }
        }

        XCTAssertEqual(produced, drained, "Drain loop must not accumulate a backlog")
        XCTAssertEqual(buffer.totalDroppedFrames, 0)
    }

    func testOverflowIsCountedRatherThanSilent() {
        let buffer = AudioRingBuffer(capacityFrames: 4800, channels: 1)
        for _ in 0..<10 {
            buffer.write(data: [Float](repeating: 1.0, count: chunk), count: chunk)
        }
        XCTAssertGreaterThan(buffer.totalDroppedFrames, 0, "Dropped audio must be reported")
    }

    func testAvailableFramesTracksUnreadAudio() {
        let buffer = AudioRingBuffer(capacityFrames: 100, channels: 1)
        buffer.write(data: [Float](repeating: 1.0, count: 30), count: 30)
        XCTAssertEqual(buffer.availableFrames, 30)
        _ = buffer.read(count: 10)
        XCTAssertEqual(buffer.availableFrames, 20)
    }

    func testStopFlushesAndExportsBufferedMicAudio() async throws {
        let tap = AudioRingBuffer(capacityFrames: 48_000, channels: 2)
        let mic = AudioRingBuffer(capacityFrames: 48_000, channels: 1)
        let writer = try SessionWriter(sessionID: UUID(), tapBuffer: tap, micBuffer: mic)
        defer { try? FileManager.default.removeItem(at: writer.sessionURL) }

        writer.startPolling()
        mic.write(data: [Float](repeating: 0.1, count: 4_801), count: 4_801)
        try await writer.stopAndFinalize()

        XCTAssertTrue(FileManager.default.fileExists(atPath: writer.m4aURL.path))
        let duration = try await AVURLAsset(url: writer.m4aURL).load(.duration)
        XCTAssertGreaterThan(duration.seconds, 0.09)
        XCTAssertLessThan(duration.seconds, 0.2)
    }
}
