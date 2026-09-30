import AVFoundation
import os

/// Converts system audio from whatever format the source delivers into
/// them.caf's format: 48 kHz, stereo, interleaved Float32.
///
/// The capture sources do not promise that format. A process tap runs at the
/// output device's rate (44.1 kHz on many devices, and it can change mid
/// session), and ScreenCaptureKit hands back non-interleaved buffers. Writing
/// either straight into a file declared 48 kHz interleaved stereo produces
/// wrong-speed or mis-interleaved audio, which is heard as static.
final class SystemAudioConverter {
    static let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                            sampleRate: 48_000,
                                            channels: 2,
                                            interleaved: true)!

    private var sourceFormat: AVAudioFormat?
    private var converter: AVAudioConverter?

    /// Buffers dropped because they could not be converted. Non-zero means the
    /// recording has gaps.
    private(set) var failedBuffers = 0

    /// Description of the most recent source format, for diagnostics.
    private(set) var sourceFormatDescription: String?

    /// Converts `input` and passes the interleaved stereo samples to `body`.
    /// Returns the number of output frames produced.
    @discardableResult
    func convert(_ input: AVAudioPCMBuffer,
                 _ body: (UnsafePointer<Float>, _ sampleCount: Int) -> Void) -> Int {
        guard input.frameLength > 0 else { return 0 }
        guard let converter = converter(for: input.format) else {
            failedBuffers += 1
            return 0
        }

        let output = Self.outputFormat
        let ratio = output.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount((Double(input.frameLength) * ratio).rounded(.up)) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else {
            failedBuffers += 1
            return 0
        }

        var consumed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return input
        }
        guard status != .error, error == nil else {
            failedBuffers += 1
            return 0
        }

        let frames = Int(out.frameLength)
        // Interleaved output keeps every channel in the first buffer.
        if frames > 0, let samples = out.floatChannelData?[0] {
            body(samples, frames * Int(output.channelCount))
        }
        return frames
    }

    private func converter(for format: AVAudioFormat) -> AVAudioConverter? {
        if let converter, let sourceFormat, sourceFormat == format {
            return converter
        }
        guard format.sampleRate > 0, format.channelCount > 0,
              let newConverter = AVAudioConverter(from: format, to: Self.outputFormat) else {
            return nil
        }
        switch format.channelCount {
        case 1:
            // Mono sources go to both ears rather than the left channel only.
            newConverter.channelMap = [0, 0]
        case 2:
            break
        default:
            // Keep the front pair of a multi-channel source.
            newConverter.channelMap = [0, 1]
        }
        converter = newConverter
        sourceFormat = format
        sourceFormatDescription = Self.describe(format)
        return newConverter
    }

    /// An AVAudioFormat for a CoreAudio stream description. AVAudioFormat
    /// refuses descriptions with more than two channels unless given a
    /// layout, so those get a discrete one instead of failing outright.
    static func format(for description: AudioStreamBasicDescription) -> AVAudioFormat? {
        var asbd = description
        if let format = AVAudioFormat(streamDescription: &asbd) { return format }
        guard let layout = AVAudioChannelLayout(
            layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | asbd.mChannelsPerFrame) else { return nil }
        return AVAudioFormat(streamDescription: &asbd, channelLayout: layout)
    }

    static func describe(_ format: AVAudioFormat) -> String {
        "\(Int(format.sampleRate)) Hz, \(format.channelCount) ch, \(format.isInterleaved ? "interleaved" : "non-interleaved")"
    }
}
