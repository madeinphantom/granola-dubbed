import Foundation
import AVFoundation
import OSLog

final class DualCaptureSession {
    private let logger = Logger(subsystem: "app.atrium.capture", category: "DualCaptureSession")
    private var tapCapture: SystemAudioTap?
    private var micCapture: MicCapture?
    private var writer: SessionWriter?
    private let clockAligner = ClockAligner()
    
    // We assume 48kHz stereo for system tap, mono for mic.
    private let tapRingBuffer = AudioRingBuffer(capacityFrames: 48000 * 10, channels: 2) // 10 seconds buffer
    private let micRingBuffer = AudioRingBuffer(capacityFrames: 48000 * 10, channels: 1)

    /// Scratch space for folding multi-channel voice-processed mic input to mono.
    private var micDownmixBuffer: [Float] = []
    
    let sessionID = UUID()
    
    private var sckFallback: SCKFallbackCapture?
    
    /// Starts microphone capture and the best available system-audio source.
    /// The returned value is false when system audio is unavailable; that is
    /// recoverable because the microphone recording remains useful.
    func start(captureSystemAudio: Bool) async throws -> Bool {
        clockAligner.reset()
        writer = try SessionWriter(sessionID: sessionID, tapBuffer: tapRingBuffer, micBuffer: micRingBuffer)

        var systemAudioStarted = false
        // Try CoreAudio tap first (preferred — pre-volume, lower latency)
        if captureSystemAudio {
          tapCapture = SystemAudioTap()
          do {
            try tapCapture?.start { [weak self] bufferList, _, timeStamp in
                self?.handleSystemAudio(bufferList: bufferList, timeStamp: timeStamp)
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

        // MicCapture is the sole microphone source, including in SCK fallback
        // mode. This keeps one format/downmix path and prevents duplicate mic.
        let mic = MicCapture()
        do {
            try mic.start { [weak self] buffer, time in
                self?.handleMicAudio(buffer: buffer, time: time)
            }
            micCapture = mic
        } catch {
            tapCapture?.stop()
            tapCapture = nil
            try? await sckFallback?.stop()
            sckFallback = nil
            writer?.discardUnstartedSession()
            writer = nil
            throw error
        }

        writer?.startPolling()
        return systemAudioStarted
    }

    func stop() async throws {
        tapCapture?.stop()
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
    
    private func handleSystemAudio(bufferList: UnsafePointer<AudioBufferList>, timeStamp: AudioTimeStamp) {
        let numBuffers = Int(bufferList.pointee.mNumberBuffers)
        
        if numBuffers == 1 {
            let buffer = bufferList.pointee.mBuffers
            if let data = buffer.mData {
                let floatData = data.assumingMemoryBound(to: Float.self)
                let sampleCount = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                tapRingBuffer.write(data: floatData, count: sampleCount)
            }
        } else {
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
            let framesPerBuffer = Int(buffers[0].mDataByteSize) / MemoryLayout<Float>.size
            var interleaved = [Float](repeating: 0, count: framesPerBuffer * numBuffers)
            
            for ch in 0..<numBuffers {
                if let data = buffers[ch].mData {
                    let chData = data.assumingMemoryBound(to: Float.self)
                    for frame in 0..<framesPerBuffer {
                        interleaved[frame * numBuffers + ch] = chData[frame]
                    }
                }
            }
            
            interleaved.withUnsafeBufferPointer { ptr in
                tapRingBuffer.write(data: ptr.baseAddress!, count: interleaved.count)
            }
        }
    }
    
    private func handleMicAudio(buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        guard let channelData = buffer.floatChannelData else { return }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }

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
    
    // SCK fallback handlers — extract float samples from CMSampleBuffer
    private func handleSCKSystemAudio(sampleBuffer: CMSampleBuffer) {
        extractAndWrite(sampleBuffer: sampleBuffer, to: tapRingBuffer)
    }
    
    private func extractAndWrite(sampleBuffer: CMSampleBuffer, to ringBuffer: AudioRingBuffer) {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)
        
        guard let ptr = dataPointer else { return }
        let floatPtr = UnsafeRawPointer(ptr).assumingMemoryBound(to: Float.self)
        let count = length / MemoryLayout<Float>.size
        ringBuffer.write(data: floatPtr, count: count)
    }
}
