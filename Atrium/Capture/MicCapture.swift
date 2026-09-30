import AVFoundation

final class MicCapture {
    let engine = AVAudioEngine()
    private var tapInstalled = false
    /// Format the input node delivered before conversion, for diagnostics.
    private(set) var inputFormat: AVAudioFormat?

    func start(handler: @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void) throws {
        let input = engine.inputNode

        // Enable AEC *before* reading the format: voice processing changes the
        // input node's format (observed: 1ch -> 9ch on built-in mics). Reading
        // it first and installing the tap with that stale format made the tap
        // deliver buffers that did not match, and most of the microphone audio
        // was lost — a 6 minute recording produced a 1 minute you.caf.
        do {
            try input.setVoiceProcessingEnabled(true)
            // Voice processing ducks all other audio by default, so starting
            // a recording turned the meeting (and anything else playing) down
            // in the user's ears and in them.caf alike. Duck as little as the
            // API allows.
            input.voiceProcessingOtherAudioDuckingConfiguration =
                AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false,
                                                                     duckingLevel: .min)
        } catch {
            // Not fatal: without AEC the mic may pick up speaker bleed, but a
            // recording with echo beats no recording at all.
            print("Voice processing unavailable: \(error.localizedDescription)")
        }

        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw MicCaptureError.invalidInputFormat
        }

        inputFormat = format

        // you.caf is written as 48 kHz mono. Voice processing does not keep the
        // hardware rate (a 24 kHz input made a ~8 s session produce a 3.8 s
        // you.caf), so convert every buffer to the file's format here instead
        // of trusting whatever the input node negotiates.
        guard let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                               sampleRate: 48_000,
                                               channels: 1,
                                               interleaved: false),
              let converter = AVAudioConverter(from: format, to: outputFormat) else {
            throw MicCaptureError.invalidInputFormat
        }
        if format.channelCount > 1 {
            // With voice processing, channel 0 is the echo-cancelled voice and
            // the rest are raw capsules. Keep channel 0: mixing in the raw
            // channels would bring the speaker echo back.
            converter.channelMap = [0]
        }

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buf, time in
            let ratio = outputFormat.sampleRate / format.sampleRate
            let capacity = AVAudioFrameCount(Double(buf.frameLength) * ratio) + 32
            guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }
            var consumed = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if consumed {
                    status.pointee = .noDataNow
                    return nil
                }
                consumed = true
                status.pointee = .haveData
                return buf
            }
            if error == nil, out.frameLength > 0 {
                handler(out, time)
            }
        }
        tapInstalled = true
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            tapInstalled = false
            throw error
        }
    }

    /// The format the tap actually delivers, valid once `start` has run.
    var currentFormat: AVAudioFormat {
        engine.inputNode.inputFormat(forBus: 0)
    }

    func stop() {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.stop()
    }

    deinit {
        stop()
    }
}

enum MicCaptureError: LocalizedError {
    case invalidInputFormat

    var errorDescription: String? {
        switch self {
        case .invalidInputFormat:
            return "The microphone reported an unusable audio format."
        }
    }
}
