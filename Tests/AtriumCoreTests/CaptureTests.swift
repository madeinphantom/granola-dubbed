import AVFoundation
import Foundation
import Testing
@testable import AtriumCore

@Suite struct RingBufferTests {
    @Test func readsBackWhatWasWritten() {
        let ring = AudioRingBuffer(capacitySamples: 10)
        ring.write([1, 2, 3], count: 3)
        #expect(ring.read(maxCount: 10) == [1, 2, 3])
        #expect(ring.read(maxCount: 1) == nil)
    }

    @Test func overflowKeepsNewestAndCountsTheLoss() {
        let ring = AudioRingBuffer(capacitySamples: 4)
        ring.write([1, 2, 3, 4, 5], count: 5)
        #expect(ring.droppedSamples == 1)
        #expect(ring.read(maxCount: 4) == [2, 3, 4, 5])
    }

    @Test func silenceIsZeros() {
        let ring = AudioRingBuffer(capacitySamples: 20_000)
        ring.writeSilence(count: 10_000)
        #expect(ring.availableSamples == 10_000)
        #expect(ring.read(maxCount: 10_000)?.allSatisfy { $0 == 0 } == true)
    }
}

@Suite struct TrackStartAlignmentTests {
    private let rate = 48_000.0

    @Test func audioBeforeArmingIsDropped() {
        var aligner = TrackStartAligner()
        let unarmed = aligner.admit(bufferHostTime: 100, armedAt: nil, sampleRate: rate)
        let early = aligner.admit(bufferHostTime: 100, armedAt: 200, sampleRate: rate)
        #expect(unarmed == nil)
        #expect(early == nil)
    }

    @Test func lateFirstBufferIsPaddedByItsDelay() throws {
        // The tap's first buffer arrives 250 ms after arming: the track must
        // start with 250 ms of silence so it lines up with the microphone.
        var aligner = TrackStartAligner()
        let armed: UInt64 = 1_000_000
        let late = armed + HostClock.ticks(seconds: 0.25)
        let admitted = aligner.admit(bufferHostTime: late, armedAt: armed, sampleRate: rate)
        let padding = try #require(admitted)
        #expect(abs(padding - 12_000) <= 1)
        let next = aligner.admit(bufferHostTime: late + 1000, armedAt: armed, sampleRate: rate)
        #expect(next == 0)
    }

    @Test func twoTracksStartingAtDifferentTimesEndUpAligned() throws {
        // Mic buffers flow from before arming; the tap starts 400 ms after.
        let armed = HostClock.ticks(seconds: 100)
        let bufferTicks = HostClock.ticks(seconds: 1024 / rate)
        var mic = TrackStartAligner(), tap = TrackStartAligner()
        var micSamples = 0, tapSamples = 0
        var t = armed - HostClock.ticks(seconds: 1)
        let end = armed + HostClock.ticks(seconds: 5)
        while t < end {
            if let pad = mic.admit(bufferHostTime: t, armedAt: armed, sampleRate: rate) { micSamples += pad + 1024 }
            if t >= armed + HostClock.ticks(seconds: 0.4),
               let pad = tap.admit(bufferHostTime: t, armedAt: armed, sampleRate: rate) { tapSamples += pad + 1024 }
            t += bufferTicks
        }
        #expect(abs(micSamples - tapSamples) <= 1024, "tracks differ by \(micSamples - tapSamples) samples")
    }
}

@Suite struct SystemAudioConverterTests {
    private func description(rate: Double, channels: UInt32, interleaved: Bool) -> AudioStreamBasicDescription {
        let bytesPerFrame = UInt32(4) * (interleaved ? channels : 1)
        return AudioStreamBasicDescription(
            mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
                | (interleaved ? 0 : kAudioFormatFlagIsNonInterleaved),
            mBytesPerPacket: bytesPerFrame, mFramesPerPacket: 1, mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: channels, mBitsPerChannel: 32, mReserved: 0)
    }

    /// Two seconds of a 1 kHz sine in 512-frame buffers; `silentRight` leaves
    /// channel 1 empty.
    private func sine(rate: Double, channels: UInt32, interleaved: Bool,
                      silentRight: Bool = false) throws -> [AVAudioPCMBuffer] {
        let format = try #require(SystemAudioConverter.format(
            for: description(rate: rate, channels: channels, interleaved: interleaved)))
        var buffers: [AVAudioPCMBuffer] = []
        var n = 0
        while n < Int(rate * 2) {
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512))
            buffer.frameLength = 512
            let list = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            for i in 0..<512 {
                let value = Float(0.5 * sin(2 * Double.pi * 1000 * Double(n + i) / rate))
                for c in 0..<Int(channels) {
                    let data = try #require(list[interleaved ? 0 : c].mData).assumingMemoryBound(to: Float.self)
                    data[interleaved ? i * Int(channels) + c : i] = (silentRight && c == 1) ? 0 : value
                }
            }
            buffers.append(buffer)
            n += 512
        }
        return buffers
    }

    private func convertsCleanly(rate: Double, channels: UInt32, interleaved: Bool,
                                 silentRight: Bool = false) throws {
        let converter = SystemAudioConverter()
        var output: [Float] = []
        for buffer in try sine(rate: rate, channels: channels, interleaved: interleaved, silentRight: silentRight) {
            converter.convert(buffer) { samples, count in
                output.append(contentsOf: UnsafeBufferPointer(start: samples, count: count))
            }
        }
        #expect(converter.failedBuffers == 0)
        #expect(abs(Double(output.count) / 48_000 - 2) < 0.03, "duration must match real time at 48 kHz")
        let middle = output.count / 2
        let tone = try #require(ToneAnalysis.analyse(output[middle..<(middle + 9_600)], sampleRate: 48_000))
        #expect(abs(tone.frequency - 1000) < 2)
        #expect(tone.snrDB > 40)
    }

    @Test func nativeStereo() throws { try convertsCleanly(rate: 48_000, channels: 2, interleaved: true) }
    @Test func resamples44100() throws { try convertsCleanly(rate: 44_100, channels: 2, interleaved: true) }
    @Test func resamplesAirPodsHeadsetRate() throws { try convertsCleanly(rate: 24_000, channels: 2, interleaved: true) }
    @Test func nonInterleaved() throws { try convertsCleanly(rate: 48_000, channels: 2, interleaved: false) }
    @Test func mono() throws { try convertsCleanly(rate: 48_000, channels: 1, interleaved: false) }
    @Test func manyChannels() throws { try convertsCleanly(rate: 48_000, channels: 12, interleaved: true) }
    @Test func audioOnOneSideIsKept() throws {
        try convertsCleanly(rate: 48_000, channels: 2, interleaved: true, silentRight: true)
    }

    private func frames(_ buffers: [(channels: UInt32, bytes: UInt32)], format: AudioStreamBasicDescription) -> Int? {
        let list = AudioBufferList.allocate(maximumBuffers: buffers.count)
        defer { free(list.unsafeMutablePointer) }
        for (i, b) in buffers.enumerated() {
            list[i] = AudioBuffer(mNumberChannels: b.channels, mDataByteSize: b.bytes, mData: nil)
        }
        return SystemAudioTap.frameCount(list, matching: format)
    }

    @Test func tapBufferValidation() {
        let stereo = description(rate: 48_000, channels: 2, interleaved: true)
        #expect(frames([(2, 4096)], format: stereo) == 512)
        // What the old aggregate delivered with AirPods: two stereo buffers.
        #expect(frames([(2, 3840), (2, 3840)], format: stereo) == nil)
        #expect(frames([(12, 24576)], format: stereo) == nil)
    }

    @Test func toneAnalysisCatchesWrongRateAndGarble() throws {
        let rate = 48_000.0
        let clean = (0..<14_400).map { Float(0.5 * sin(2 * Double.pi * 1000 * Double($0) / rate)) }
        #expect(try #require(ToneAnalysis.analyse(clean[...], sampleRate: rate)).snrDB > 40)
        let slow = (0..<14_400).map { Float(0.5 * sin(2 * Double.pi * 500 * Double($0) / rate)) }
        #expect(abs(try #require(ToneAnalysis.analyse(slow[...], sampleRate: rate)).frequency - 500) < 2)
        let garbled = (0..<14_400).map { i -> Float in
            i % 4 < 2 ? Float(0.5 * sin(2 * Double.pi * 1000 * Double(i / 2) / rate)) : 0
        }
        let bad = try #require(ToneAnalysis.analyse(garbled[...], sampleRate: rate))
        #expect(abs(bad.frequency - 1000) > 5 || bad.snrDB < 20)
    }
}

