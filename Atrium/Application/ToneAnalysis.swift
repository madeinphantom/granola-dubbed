import AVFoundation
import Foundation

/// Objective check that captured audio is clean, not merely loud.
///
/// An RMS check passes static: garbled system audio is just as loud as the
/// real thing. A pure tone played through the speakers must come back at the
/// same frequency with almost all of its energy in that one sinusoid. A wrong
/// sample rate moves the frequency; mis-interleaved or mixed-up buffers spread
/// the energy across the spectrum and collapse the signal-to-noise ratio.
struct ToneAnalysis: Codable, Equatable {
    /// Strongest frequency in the window, in Hz.
    var frequency: Double
    /// Power of that sinusoid against everything else in the window, in dB.
    var snrDB: Double

    /// Analyses one window of mono samples, searching 20 Hz to 12 kHz.
    static func analyse(_ samples: ArraySlice<Float>, sampleRate: Double) -> ToneAnalysis? {
        let window = samples.map(Double.init)
        guard window.count >= 256, sampleRate > 0 else { return nil }
        let totalPower = window.reduce(0) { $0 + $1 * $1 } / Double(window.count)
        guard totalPower > 0 else { return nil }

        var best = 0.0
        var bestPower = 0.0
        func consider(_ frequency: Double) {
            let power = sinusoidPower(window, frequency: frequency, sampleRate: sampleRate)
            if power > bestPower {
                bestPower = power
                best = frequency
            }
        }
        // Coarse scan, then refine around the peak.
        var f = 20.0
        while f <= min(12_000, sampleRate / 2) {
            consider(f)
            f += 5
        }
        var g = best - 5
        let coarsePeak = best
        while g <= coarsePeak + 5 {
            consider(g)
            g += 0.25
        }
        let residual = max(totalPower - bestPower, totalPower * 1e-12)
        return ToneAnalysis(frequency: best, snrDB: 10 * log10(bestPower / residual))
    }

    /// Mean power of the component of `window` at `frequency` (least-squares
    /// fit of one sine/cosine pair).
    static func sinusoidPower(_ window: [Double], frequency: Double, sampleRate: Double) -> Double {
        let step = 2 * Double.pi * frequency / sampleRate
        // Rotate a unit phasor instead of calling sin/cos per sample.
        let rotCos = cos(step)
        let rotSin = sin(step)
        var pc = 1.0
        var ps = 0.0
        var s = 0.0
        var c = 0.0
        for x in window {
            s += x * ps
            c += x * pc
            let next = pc * rotCos - ps * rotSin
            ps = ps * rotCos + pc * rotSin
            pc = next
        }
        let n = Double(window.count)
        let a = 2 * s / n
        let b = 2 * c / n
        return (a * a + b * b) / 2
    }

    /// Reads a track and folds it to mono for analysis.
    static func monoSamples(of url: URL) -> (samples: [Float], sampleRate: Double)? {
        guard let file = try? AVAudioFile(forReading: url),
              file.length > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil,
              let channels = buffer.floatChannelData else { return nil }
        let count = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        var mono = [Float](repeating: 0, count: count)
        for ch in 0..<channelCount {
            let data = channels[ch]
            for i in 0..<count { mono[i] += data[i] / Float(channelCount) }
        }
        return (mono, file.processingFormat.sampleRate)
    }

    /// Writes a pure sine tone as a 44.1 kHz WAV, so playback also exercises
    /// a rate different from the capture format.
    static func writeTone(frequency: Double, seconds: Double, to url: URL) throws {
        let rate = 44_100.0
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(rate * seconds)),
              let data = buffer.floatChannelData?[0] else {
            throw CocoaError(.fileWriteUnknown)
        }
        buffer.frameLength = buffer.frameCapacity
        let fade = Int(rate * 0.01)
        let count = Int(buffer.frameLength)
        for i in 0..<count {
            let envelope = Float(min(1, Double(min(i, count - 1 - i)) / Double(fade)))
            data[i] = 0.3 * envelope * Float(sin(2 * Double.pi * frequency * Double(i) / rate))
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        try file.write(from: buffer)
    }
}
