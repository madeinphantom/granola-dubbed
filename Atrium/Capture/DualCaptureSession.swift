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
    private var usingSCKFallback = false
    
    func start() throws {
        clockAligner.reset()
        writer = try SessionWriter(sessionID: sessionID, tapBuffer: tapRingBuffer, micBuffer: micRingBuffer)
        
        // Try CoreAudio tap first (preferred — pre-volume, lower latency)
        tapCapture = SystemAudioTap()
        do {
            try tapCapture?.start { [weak self] bufferList, _, timeStamp in
                self?.handleSystemAudio(bufferList: bufferList, timeStamp: timeStamp)
            }
            logger.info("Using CoreAudio tap for system audio")
        } catch {
            logger.warning("CoreAudio tap failed: \(error.localizedDescription). Falling back to SCK.")
            tapCapture = nil
            
            // Fallback: ScreenCaptureKit captures both system audio and mic
            sckFallback = SCKFallbackCapture()
            sckFallback?.onSystemAudio = { [weak self] sampleBuffer in
                self?.handleSCKSystemAudio(sampleBuffer: sampleBuffer)
            }
            sckFallback?.onMicAudio = { [weak self] sampleBuffer in
                self?.handleSCKMicAudio(sampleBuffer: sampleBuffer)
            }
            
            Task {
                do {
                    try await sckFallback?.start()
                    usingSCKFallback = true
                    logger.info("Using SCK fallback for capture")
                } catch {
                    logger.error("SCK fallback also failed: \(error.localizedDescription)")
                }
            }
        }
        
        // Only start mic capture if NOT using SCK (which already captures mic)
        if !usingSCKFallback {
            micCapture = MicCapture()
            try micCapture?.start { [weak self] buffer, time in
                self?.handleMicAudio(buffer: buffer, time: time)
            }
        }
        
        writer?.startPolling()
    }
    
    func stop() async {
        tapCapture?.stop()
        micCapture?.stop()
        
        if usingSCKFallback {
            try? await sckFallback?.stop()
        }
        
        do {
            try await writer?.stopAndFinalize()
        } catch {
            logger.error("Failed to finalize session: \(error.localizedDescription)")
        }
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
    
    private func handleSCKMicAudio(sampleBuffer: CMSampleBuffer) {
        extractAndWrite(sampleBuffer: sampleBuffer, to: micRingBuffer)
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
