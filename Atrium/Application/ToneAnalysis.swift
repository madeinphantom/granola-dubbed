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
    /// Power of that sinusoid against everything else above 300 Hz, in dB.
    var snrDB: Double
    /// Peak amplitude of that sinusoid (full scale is 1).
    var amplitude: Double

    /// Analyses one window of mono samples, searching 20 Hz to 12 kHz.
    ///
    /// Content below ~300 Hz is filtered out first. The self-test runs on a
    /// real Mac where other apps may be playing (music, a video): that audio
    /// is legitimately in them.caf and mostly bass, while the damage a broken
    /// capture does to a 1 kHz tone (images, clicks, garble) lands higher.
    static func analyse(_ samples: ArraySlice<Float>, sampleRate: Double) -> ToneAnalysis? {
        guard samples.count >= 512, sampleRate > 0 else { return nil }
        let settle = Int(sampleRate * 0.005)
        let window = Array(highPass(samples.map(Double.init), cutoff: 300, sampleRate: sampleRate)
            .dropFirst(min(settle, samples.count / 4)))
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
        return ToneAnalysis(frequency: best,
                            snrDB: 10 * log10(bestPower / residual),
                            amplitude: (2 * bestPower).squareRoot())
    }

    /// Two cascaded one-pole high-pass filters.
    static func highPass(_ x: [Double], cutoff: Double, sampleRate: Double) -> [Double] {
        let rc = 1 / (2 * Double.pi * cutoff)
        let alpha = rc / (rc + 1 / sampleRate)
        var y = x
        for _ in 0..<2 {
            var previousIn = y.first ?? 0
            var previousOut = 0.0
            for i in y.indices {
                let input = y[i]
                previousOut = alpha * (previousOut + input - previousIn)
                previousIn = input
                y[i] = previousOut
            }
        }
        return y
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
    static func writeTone(frequency: Double, seconds: Double, amplitude: Float, to url: URL) throws {
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
            data[i] = amplitude * envelope * Float(sin(2 * Double.pi * frequency * Double(i) / rate))
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
