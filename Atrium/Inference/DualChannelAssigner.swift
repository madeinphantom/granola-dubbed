import Foundation
import Accelerate
import AVFoundation
import OSLog

final class DualChannelAssigner {
    private let logger = Logger(subsystem: "app.atrium.infer", category: "DualChannelAssigner")
    
    func assign(youTrackURL: URL, themTrackURL: URL, chunkSizeSeconds: TimeInterval = 0.5) throws -> [(start: TimeInterval, end: TimeInterval, speaker: String)] {
        guard let youFile = try? AVAudioFile(forReading: youTrackURL),
              let themFile = try? AVAudioFile(forReading: themTrackURL) else {
            return []
        }
        
        let sampleRate = youFile.processingFormat.sampleRate
        let frameCount = AVAudioFrameCount(chunkSizeSeconds * sampleRate)
        
        guard let youBuffer = AVAudioPCMBuffer(pcmFormat: youFile.processingFormat, frameCapacity: frameCount),
              let themBuffer = AVAudioPCMBuffer(pcmFormat: themFile.processingFormat, frameCapacity: frameCount) else {
            return []
        }
        
        var segments: [(start: TimeInterval, end: TimeInterval, speaker: String)] = []
        var currentTime: TimeInterval = 0
        let energyThreshold: Float = 0.01
        
        while youFile.framePosition < youFile.length && themFile.framePosition < themFile.length {
            try youFile.read(into: youBuffer, frameCount: frameCount)
            try themFile.read(into: themBuffer, frameCount: frameCount)
            
            guard let youData = youBuffer.floatChannelData?[0],
                  let themData = themBuffer.floatChannelData?[0] else { break }
            
            let youArray = Array(UnsafeBufferPointer(start: youData, count: Int(youBuffer.frameLength)))
            let themArray = Array(UnsafeBufferPointer(start: themData, count: Int(themBuffer.frameLength)))
            
            var youRMS: Float = 0
            var themRMS: Float = 0
            
            vDSP_rmsqv(youArray, 1, &youRMS, vDSP_Length(youArray.count))
            vDSP_rmsqv(themArray, 1, &themRMS, vDSP_Length(themArray.count))
            
            var speaker = "Unknown"
            if youRMS > energyThreshold && themRMS < energyThreshold {
                speaker = "You"
            } else if themRMS > energyThreshold && youRMS < energyThreshold {
                speaker = "Them"
            } else if youRMS > energyThreshold && themRMS > energyThreshold {
                speaker = youRMS > themRMS ? "You" : "Them"
            }
            
            if speaker != "Unknown" {
                if let last = segments.last, last.speaker == speaker {
                    segments[segments.count - 1].end = currentTime + chunkSizeSeconds
                } else {
                    segments.append((start: currentTime, end: currentTime + chunkSizeSeconds, speaker: speaker))
                }
            }
            
            currentTime += chunkSizeSeconds
        }
        
        return segments
    }
}
