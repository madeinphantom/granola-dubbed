import AVFoundation

final class MicCapture {
    let engine = AVAudioEngine()

    func start(handler: @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void) throws {
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        try input.setVoiceProcessingEnabled(true) // AEC against system playback
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buf, time in
            handler(buf, time)
        }
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
    
    deinit {
        stop()
    }
}
