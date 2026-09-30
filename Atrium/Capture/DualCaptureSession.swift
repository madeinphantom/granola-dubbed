import Foundation
import AVFoundation
import OSLog

final class DualCaptureSession {
    private let logger = Logger(subsystem: "app.atrium.capture", category: "DualCaptureSession")
    private var tapCapture: SystemAudioTap?
    private var micCapture: MicCapture?
    private var writer: SessionWriter?
    private let clockAligner = ClockAligner()
    
    // Both rings hold audio already converted to the file formats: 48 kHz
    // interleaved stereo for system audio, 48 kHz mono for the mic.
    private let tapRingBuffer = AudioRingBuffer(capacityFrames: 48000 * 10, channels: 2) // 10 seconds buffer
    private let micRingBuffer = AudioRingBuffer(capacityFrames: 48000 * 10, channels: 1)

    /// Scratch space for folding multi-channel voice-processed mic input to mono.
    private var micDownmixBuffer: [Float] = []

    /// Converts system audio to them.caf's format. Only one system source
    /// (tap or ScreenCaptureKit) runs at a time, so they share it.
    private let systemConverter = SystemAudioConverter()
    
    let sessionID = UUID()

    /// Frames delivered by each capture source, for diagnostics. Written from
    /// audio threads; read only after `stop()` has returned.
    private(set) var micFramesReceived = 0
    private(set) var systemCallbacksReceived = 0
    private(set) var micInputFormatDescription: String?
    /// Source format of system audio before conversion, e.g. "48000 Hz, 2 ch, interleaved".
    var systemInputFormatDescription: String? { systemConverter.sourceFormatDescription }
    /// System-audio frames written after conversion to 48 kHz.
    private(set) var systemFramesWritten = 0
    /// Tap callbacks dropped because their layout did not match the tap format.
    private(set) var systemFormatMismatches = 0
    var systemConversionFailures: Int { systemConverter.failedBuffers }
    
    private var sckFallback: SCKFallbackCapture?
    
    /// Starts microphone capture and the best available system-audio source.
    /// The returned value is false when system audio is unavailable; that is
    /// recoverable because the microphone recording remains useful.
    func start(captureSystemAudio: Bool) async throws -> Bool {
        clockAligner.reset()
        writer = try SessionWriter(sessionID: sessionID, tapBuffer: tapRingBuffer, micBuffer: micRingBuffer)

        // The microphone starts first: voice-processing startup takes about a
        // second, and starting it after the system tap left you.caf shorter
        // than them.caf and misaligned for speaker attribution.
        // MicCapture is the sole microphone source, including in SCK fallback
        // mode. This keeps one format/downmix path and prevents duplicate mic.
        let mic = MicCapture()
        do {
            try mic.start { [weak self] buffer, time in
                self?.handleMicAudio(buffer: buffer, time: time)
            }
            micCapture = mic
            if let f = mic.inputFormat {
                micInputFormatDescription = "\(Int(f.sampleRate)) Hz, \(f.channelCount) ch"
            }
        } catch {
            writer?.discardUnstartedSession()
            writer = nil
            throw error
        }

        var systemAudioStarted = false
        // Try CoreAudio tap first (preferred — pre-volume, lower latency)
        if captureSystemAudio {
          tapCapture = SystemAudioTap()
          do {
            try tapCapture?.start { [weak self] buffer in
                self?.handleSystemAudio(buffer: buffer)
            }
            logger.info("Using CoreAudio tap for system audio")
            systemAudioStarted = true
        } catch {
            logger.warning("CoreAudio tap failed: \(error.localizedDescription). Falling back to SCK.")
            tapCapture?.stop()
            tapCapture = nil

            // Await fallback startup before returning. A detached startup
            // raced the mic and allowed a session to appear active before SCK
            // had either started or failed.
            let fallback = SCKFallbackCapture()
            fallback.onSystemAudio = { [weak self] sampleBuffer in
                self?.handleSCKSystemAudio(sampleBuffer: sampleBuffer)
            }
            do {
                try await fallback.start()
                sckFallback = fallback
                systemAudioStarted = true
                logger.info("Using SCK fallback for system audio")
            } catch {
                logger.error("SCK fallback also failed; continuing with microphone only: \(error.localizedDescription)")
            }
          }
        }

        writer?.startPolling()
        return systemAudioStarted
    }

    func stop() async throws {
        tapCapture?.stop()
        systemFormatMismatches = tapCapture?.mismatchedCallbacks ?? 0
        tapCapture = nil
        micCapture?.stop()

        if let fallback = sckFallback {
            do {
                try await fallback.stop()
            } catch {
                logger.error("Could not stop SCK capture cleanly: \(error.localizedDescription)")
            }
        }
        sckFallback = nil

        try await writer?.stopAndFinalize()
        writer = nil
    }
    
    private func handleSystemAudio(buffer: AVAudioPCMBuffer) {
        systemCallbacksReceived += 1
        writeSystemAudio(buffer)
    }

    private func writeSystemAudio(_ buffer: AVAudioPCMBuffer) {
        systemFramesWritten += systemConverter.convert(buffer) { samples, count in
            tapRingBuffer.write(data: samples, count: count)
        }
    }

    private func handleMicAudio(buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        guard let channelData = buffer.floatChannelData else { return }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }
        micFramesReceived += frameCount

        let channels = Int(buffer.format.channelCount)

        // you.caf is written as mono. Voice processing can hand back a
        // multi-channel buffer (9ch on built-in mics), so fold it down rather
        // than assuming channel 0 alone represents the microphone.
        if channels <= 1 {
            micRingBuffer.write(data: channelData[0], count: frameCount)
            return
        }

        if micDownmixBuffer.count < frameCount {
            micDownmixBuffer = [Float](repeating: 0, count: frameCount)
        }
        let scale = 1.0 / Float(channels)
        micDownmixBuffer.withUnsafeMutableBufferPointer { out in
            for frame in 0..<frameCount { out[frame] = 0 }
            for ch in 0..<channels {
                let src = channelData[ch]
                for frame in 0..<frameCount {
                    out[frame] += src[frame] * scale
                }
            }
        }
        micDownmixBuffer.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return }
            micRingBuffer.write(data: base, count: frameCount)
        }
    }
    
    // ScreenCaptureKit delivers non-interleaved Float32; copying its raw bytes
    // into the interleaved ring put all left samples before all right ones.
    private func handleSCKSystemAudio(sampleBuffer: CMSampleBuffer) {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
        guard status == noErr else { return }
        systemCallbacksReceived += 1
        writeSystemAudio(buffer)
    }
}
