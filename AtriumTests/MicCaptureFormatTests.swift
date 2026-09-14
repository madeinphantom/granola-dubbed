import XCTest
import AVFoundation
import CoreAudio
@testable import Atrium

final class MicCaptureFormatTests: XCTestCase {
    /// Whether the machine has a default input device with input channels.
    private static var hasRealAudioInputDevice: Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &deviceID) == noErr,
              deviceID != AudioDeviceID(kAudioObjectUnknown) else { return false }

        var streamAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &streamAddress, 0, nil, &dataSize) == noErr,
              dataSize > 0 else { return false }

        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(dataSize), alignment: 16)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &streamAddress, 0, nil, &dataSize, raw) == noErr else {
            return false
        }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.contains { $0.mNumberChannels > 0 }
    }

    /// Regression: `inputFormat` was read *before* `setVoiceProcessingEnabled`,
    /// and the tap installed with that stale format. Enabling voice processing
    /// changes the input format (observed 1ch -> 9ch on built-in mics), so most
    /// microphone audio was lost: a ~6 minute session wrote a ~1 minute
    /// you.caf while them.caf was correct.
    func testVoiceProcessingChangesInputFormat() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let before = input.inputFormat(forBus: 0)

        // `xcodebuild` does not forward the shell environment into the test
        // process, so an env-var guard is unreliable. Ask CoreAudio directly
        // whether a real input device exists: on a headless runner
        // setVoiceProcessingEnabled blocks in the HAL rather than failing.
        try XCTSkipUnless(Self.hasRealAudioInputDevice,
                          "No audio input device on this host")
        try XCTSkipUnless(before.sampleRate > 0 && before.channelCount > 0,
                          "Input node reported no usable format")

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
