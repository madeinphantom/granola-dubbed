import AVFoundation

final class MicCapture {
    let engine = AVAudioEngine()
    private var tapInstalled = false

    func start(handler: @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void) throws {
        let input = engine.inputNode

        // Enable AEC *before* reading the format: voice processing changes the
        // input node's format (observed: 1ch -> 9ch on built-in mics). Reading
        // it first and installing the tap with that stale format made the tap
        // deliver buffers that did not match, and most of the microphone audio
        // was lost — a 6 minute recording produced a 1 minute you.caf.
        do {
            try input.setVoiceProcessingEnabled(true)
        } catch {
            // Not fatal: without AEC the mic may pick up speaker bleed, but a
            // recording with echo beats no recording at all.
            print("Voice processing unavailable: \(error.localizedDescription)")
        }

        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw MicCaptureError.invalidInputFormat
        }

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buf, time in
            handler(buf, time)
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
