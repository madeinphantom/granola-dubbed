import XCTest
import AVFoundation
import CoreAudio
@testable import Atrium

/// Pins the conversion that fixed static in them.caf.
///
/// The tap and ScreenCaptureKit deliver whatever rate and layout the output
/// device runs at; them.caf is 48 kHz interleaved stereo. These run on pure
/// software (AVAudioConverter), so they are safe on CI; the live tap is
/// checked by `atrium selftest` on real hardware.
final class SystemAudioConverterTests: XCTestCase {
    private func description(rate: Double, channels: UInt32, interleaved: Bool) -> AudioStreamBasicDescription {
        let bytesPerFrame = UInt32(4) * (interleaved ? channels : 1)
        return AudioStreamBasicDescription(
            mSampleRate: rate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
                | (interleaved ? 0 : kAudioFormatFlagIsNonInterleaved),
            mBytesPerPacket: bytesPerFrame, mFramesPerPacket: 1, mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: channels, mBitsPerChannel: 32, mReserved: 0)
    }

    /// Two seconds of a 1 kHz sine in 512-frame buffers of the given format.
    private func sineBuffers(rate: Double, channels: UInt32, interleaved: Bool) throws -> [AVAudioPCMBuffer] {
        let format = try XCTUnwrap(SystemAudioConverter.format(
            for: description(rate: rate, channels: channels, interleaved: interleaved)))
        var buffers: [AVAudioPCMBuffer] = []
        let chunk = 512
        var n = 0
        while n < Int(rate * 2) {
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk)))
            buffer.frameLength = AVAudioFrameCount(chunk)
            let abl = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            for i in 0..<chunk {
                let v = Float(0.5 * sin(2 * Double.pi * 1000 * Double(n + i) / rate))
                for c in 0..<Int(channels) {
                    let data = try XCTUnwrap(abl[interleaved ? 0 : c].mData).assumingMemoryBound(to: Float.self)
                    data[interleaved ? i * Int(channels) + c : i] = v
                }
            }
            buffers.append(buffer)
            n += chunk
        }
        return buffers
    }

    private func assertConvertsCleanly(rate: Double, channels: UInt32, interleaved: Bool,
                                       file: StaticString = #filePath, line: UInt = #line) throws {
        let converter = SystemAudioConverter()
        var left: [Float] = []
        var right: [Float] = []
        var frames = 0
        for buffer in try sineBuffers(rate: rate, channels: channels, interleaved: interleaved) {
            frames += converter.convert(buffer) { samples, count in
                for i in stride(from: 0, to: count, by: 2) {
                    left.append(samples[i])
                    right.append(samples[i + 1])
                }
            }
        }
        XCTAssertEqual(converter.failedBuffers, 0, file: file, line: line)
        XCTAssertEqual(Double(frames) / 48_000, 2.0, accuracy: 0.03,
                       "Duration must match real time at 48 kHz", file: file, line: line)
        for channel in [left, right] {
            let mid = channel.count / 2
            let tone = try XCTUnwrap(ToneAnalysis.analyse(channel[mid..<(mid + 9_600)], sampleRate: 48_000))
            XCTAssertEqual(tone.frequency, 1000, accuracy: 2, file: file, line: line)
            XCTAssertGreaterThan(tone.snrDB, 40, file: file, line: line)
        }
    }

    func testNativeFormatPassesThrough() throws {
        try assertConvertsCleanly(rate: 48_000, channels: 2, interleaved: true)
    }

    func testFortyFourOneIsResampled() throws {
        try assertConvertsCleanly(rate: 44_100, channels: 2, interleaved: true)
    }

    func testHeadsetProfileRateIsResampled() throws {
        // AirPods in their headset profile run the output at 24 kHz.
        try assertConvertsCleanly(rate: 24_000, channels: 2, interleaved: true)
    }

    func testNonInterleavedIsInterleaved() throws {
        // ScreenCaptureKit's layout.
        try assertConvertsCleanly(rate: 48_000, channels: 2, interleaved: false)
    }

    func testMonoGoesToBothChannels() throws {
        try assertConvertsCleanly(rate: 48_000, channels: 1, interleaved: false)
    }

    func testMultiChannelKeepsTheFrontPair() throws {
        try assertConvertsCleanly(rate: 48_000, channels: 12, interleaved: true)
    }

    // MARK: - Tap buffer validation

    private func frames(buffers: [(channels: UInt32, bytes: UInt32)],
                        format: AudioStreamBasicDescription) -> Int? {
        let abl = AudioBufferList.allocate(maximumBuffers: buffers.count)
        defer { free(abl.unsafeMutablePointer) }
        for (i, b) in buffers.enumerated() {
            abl[i] = AudioBuffer(mNumberChannels: b.channels, mDataByteSize: b.bytes, mData: nil)
        }
        return SystemAudioTap.frameCount(abl, matching: format)
    }

    func testTapBufferMatchingTheFormatIsAccepted() {
        let stereo = description(rate: 48_000, channels: 2, interleaved: true)
        XCTAssertEqual(frames(buffers: [(2, 4096)], format: stereo), 512)
    }

    func testExtraBuffersAreRejected() {
        // What the old aggregate delivered with AirPods: two stereo buffers.
        let stereo = description(rate: 48_000, channels: 2, interleaved: true)
        XCTAssertNil(frames(buffers: [(2, 3840), (2, 3840)], format: stereo))
    }

    func testExtraChannelsAreRejected() {
        let stereo = description(rate: 48_000, channels: 2, interleaved: true)
        XCTAssertNil(frames(buffers: [(12, 24576)], format: stereo))
    }

    // MARK: - Tone analysis catches static

    func testToneAnalysisRejectsWrongRateAndGarble() throws {
        let rate = 48_000.0
        let sine = (0..<14_400).map { Float(0.5 * sin(2 * Double.pi * 1000 * Double($0) / rate)) }
        let clean = try XCTUnwrap(ToneAnalysis.analyse(sine[...], sampleRate: rate))
        XCTAssertEqual(clean.frequency, 1000, accuracy: 1)
        XCTAssertGreaterThan(clean.snrDB, 40)

        // 24 kHz audio written as 48 kHz: the tone plays an octave low.
        let stretched = (0..<14_400).map { Float(0.5 * sin(2 * Double.pi * 1000 * Double($0) / 2 / rate)) }
        let slow = try XCTUnwrap(ToneAnalysis.analyse(stretched[...], sampleRate: rate))
        XCTAssertEqual(slow.frequency, 500, accuracy: 2)

        // Two stereo buffers flattened into one stereo stream, as the old
        // handler did: the left column alternates between sources.
        var garbled: [Float] = []
        for i in 0..<14_400 {
            let frame = i / 2
            let v = Float(0.5 * sin(2 * Double.pi * 1000 * Double(frame) / rate))
            garbled.append(i % 4 < 2 ? v : 0)
        }
        let bad = try XCTUnwrap(ToneAnalysis.analyse(garbled[...], sampleRate: rate))
        XCTAssertTrue(abs(bad.frequency - 1000) > 5 || bad.snrDB < 20,
                      "Garbled audio must not pass as a clean tone (got \(bad))")
    }
}
