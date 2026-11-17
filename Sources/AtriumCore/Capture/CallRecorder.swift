import AVFoundation
import Foundation
import os
import OSLog

public enum RecorderError: LocalizedError {
    case systemAudioUnavailable(String)
    case microphoneUnavailable(String)
    case nothingRecorded

    public var errorDescription: String? {
        switch self {
        case .systemAudioUnavailable(let reason):
            return "Could not capture system audio: \(reason)"
        case .microphoneUnavailable(let reason):
            return "Could not start the microphone: \(reason)"
        case .nothingRecorded:
            return "No audio was recorded."
        }
    }
}

/// What a finished recording captured, for diagnostics and the self-test.
public struct RecordingStats: Codable, Sendable {
    public var meSeconds: Double
    public var themSeconds: Double
    public var micInputFormat: String?
    public var systemInputFormat: String?
    public var systemCallbacks: Int
    public var systemFormatMismatches: Int
    public var systemConversionFailures: Int
    public var droppedSamples: Int
}

/// Records the microphone to `me.caf` and system audio to `them.caf`.
///
/// Both files are 48 kHz mono Float32 and start at the same instant: audio
/// arriving before both sources are running is dropped, and whichever source
/// delivers its first buffer late is padded with silence for the gap, measured
/// on the host clock. Without this the microphone, which starts first, ran
/// about a second ahead of system audio and the transcript interleaved the two
/// sides wrongly.
public final class CallRecorder: @unchecked Sendable {
    public static let sampleRate = 48_000.0

    public let directory: URL
    public var meURL: URL { directory.appendingPathComponent(SessionFiles.meRaw) }
    public var themURL: URL { directory.appendingPathComponent(SessionFiles.themRaw) }

    private let logger = Logger(subsystem: "app.atrium", category: "CallRecorder")
    private let mic = MicCapture()
    private let tap = SystemAudioTap()
    private let systemConverter = SystemAudioConverter()

    // Ten seconds of headroom each; the writer drains every 100 ms.
    private let meRing = AudioRingBuffer(capacitySamples: 48_000 * 10)
    private let themRing = AudioRingBuffer(capacitySamples: 48_000 * 10)

    private let armedAt = OSAllocatedUnfairLock<UInt64?>(initialState: nil)
    private var meAligner = TrackStartAligner()   // mic thread only
    private var themAligner = TrackStartAligner() // tap IO queue only
    private var systemCallbacks = 0               // tap IO queue only

    private let writeQueue = DispatchQueue(label: "app.atrium.writer")
    private var timer: DispatchSourceTimer?
    private var meFile: AVAudioFile?
    private var themFile: AVAudioFile?
    private var writeError: Error?

    public init(directory: URL) {
        self.directory = directory
    }

    public func start() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let format = AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 1)!
        meFile = try AVAudioFile(forWriting: meURL, settings: format.settings)
        themFile = try AVAudioFile(forWriting: themURL, settings: format.settings)

        // The microphone starts first: voice processing takes about a second
        // to come up. Its audio is dropped until the tap is running too.
        do {
            try mic.start { [weak self] buffer, time in
                guard let self else { return }
                let hostTime = time.isHostTimeValid ? time.hostTime : mach_absolute_time()
                self.admit(buffer, hostTime: hostTime, aligner: &self.meAligner, ring: self.meRing)
            }
        } catch {
            cleanUpFailedStart()
            throw RecorderError.microphoneUnavailable(error.localizedDescription)
        }

        do {
            try tap.start { [weak self] buffer, hostTime in
                guard let self else { return }
                self.systemCallbacks += 1
                guard let padding = self.themAligner.admit(bufferHostTime: hostTime,
                                                           armedAt: self.armedAt.withLock { $0 },
                                                           sampleRate: Self.sampleRate) else { return }
                if padding > 0 { self.themRing.writeSilence(count: padding) }
                self.systemConverter.convert(buffer) { samples, count in
                    self.themRing.write(samples, count: count)
                }
            }
        } catch {
            mic.stop()
            cleanUpFailedStart()
            throw RecorderError.systemAudioUnavailable(String(describing: error))
        }

        armedAt.withLock { $0 = mach_absolute_time() }

        let timer = DispatchSource.makeTimerSource(queue: writeQueue)
        timer.schedule(deadline: .now() + 0.1, repeating: 0.1)
        timer.setEventHandler { [weak self] in self?.drain() }
        timer.resume()
        self.timer = timer
        logger.info("Recording to \(self.directory.path, privacy: .public)")
    }

    /// Stops capture and closes both files. Safe to read them afterwards.
    public func stop() throws -> RecordingStats {
        tap.stop()
        mic.stop()
        timer?.cancel()
        timer = nil
        // Final drain on the writer's queue, after the last scheduled tick.
        writeQueue.sync {
            drain()
            meFile = nil
            themFile = nil
        }
        if let writeError { throw writeError }

        let stats = RecordingStats(
            meSeconds: Self.duration(of: meURL),
            themSeconds: Self.duration(of: themURL),
            micInputFormat: mic.inputFormat.map { "\(Int($0.sampleRate)) Hz, \($0.channelCount) ch" },
            systemInputFormat: systemConverter.sourceFormatDescription,
            systemCallbacks: systemCallbacks,
            systemFormatMismatches: tap.mismatchedCallbacks,
            systemConversionFailures: systemConverter.failedBuffers,
            droppedSamples: meRing.droppedSamples + themRing.droppedSamples)
        if stats.droppedSamples > 0 {
            logger.error("Dropped \(stats.droppedSamples) samples to buffer overflow")
        }
        guard stats.meSeconds > 0 || stats.themSeconds > 0 else { throw RecorderError.nothingRecorded }
        return stats
    }

    private func admit(_ buffer: AVAudioPCMBuffer, hostTime: UInt64,
                       aligner: inout TrackStartAligner, ring: AudioRingBuffer) {
        guard let padding = aligner.admit(bufferHostTime: hostTime,
                                          armedAt: armedAt.withLock { $0 },
                                          sampleRate: Self.sampleRate),
              let samples = buffer.floatChannelData?[0] else { return }
        if padding > 0 { ring.writeSilence(count: padding) }
        ring.write(samples, count: Int(buffer.frameLength))
    }

    private func drain() {
        do {
            try Self.drain(meRing, into: meFile)
            try Self.drain(themRing, into: themFile)
        } catch {
            if writeError == nil {
                writeError = error
                logger.error("Writing audio failed: \(error.localizedDescription)")
            }
        }
    }

    /// Writes everything currently buffered. Draining a fixed amount per tick
    /// could never catch up with a late tick, and the backlog eventually
    /// overflowed the ring and lost audio.
    private static func drain(_ ring: AudioRingBuffer, into file: AVAudioFile?) throws {
        guard let file else { return }
        while let samples = ring.read(maxCount: 48_000) {
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                          frameCapacity: AVAudioFrameCount(samples.count))!
            buffer.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { source in
                buffer.floatChannelData![0].update(from: source.baseAddress!, count: samples.count)
            }
            try file.write(from: buffer)
        }
    }

    private func cleanUpFailedStart() {
        meFile = nil
        themFile = nil
        try? FileManager.default.removeItem(at: directory)
    }

    static func duration(of url: URL) -> Double {
        guard let file = try? AVAudioFile(forReading: url) else { return 0 }
        return Double(file.length) / file.processingFormat.sampleRate
    }
}

/// Decides, per track, which buffers to keep and how much silence to insert so
/// that every track starts at the moment recording was armed.
struct TrackStartAligner {
    private(set) var started = false

    /// Returns nil to drop the buffer, otherwise the number of silent samples
    /// to write before it.
    mutating func admit(bufferHostTime: UInt64, armedAt: UInt64?, sampleRate: Double) -> Int? {
        guard let armedAt, bufferHostTime >= armedAt else { return nil }
        guard !started else { return 0 }
        started = true
        return Int((HostClock.seconds(bufferHostTime - armedAt) * sampleRate).rounded())
    }
}

enum HostClock {
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    static func seconds(_ ticks: UInt64) -> Double {
        Double(ticks) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }

    static func ticks(seconds: Double) -> UInt64 {
        UInt64(seconds * 1_000_000_000 * Double(timebase.denom) / Double(timebase.numer))
    }
}

