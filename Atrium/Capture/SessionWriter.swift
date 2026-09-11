import Foundation
import AVFoundation
import OSLog

enum SessionWriterError: LocalizedError {
    case missingIncompleteMarker
    case cannotCreateFile(String)
    case noAudioCaptured
    case exportUnavailable
    case exportProducedNoFile

    var errorDescription: String? {
        switch self {
        case .missingIncompleteMarker:
            return "Session marker missing."
        case .cannotCreateFile(let name):
            return "Could not create \(name)."
        case .noAudioCaptured:
            return "No audio was captured. Check microphone and screen-recording permissions in System Settings > Privacy & Security."
        case .exportUnavailable:
            return "Could not create the audio export session."
        case .exportProducedNoFile:
            return "Audio export finished but produced no file."
        }
    }
}

final class SessionWriter {
    private let logger = Logger(subsystem: "app.atrium.capture", category: "SessionWriter")

    let sessionURL: URL
    let youTrackURL: URL
    let themTrackURL: URL
    let incompleteMarkerURL: URL
    let m4aURL: URL
    
    private var youFile: AVAudioFile?
    private var themFile: AVAudioFile?
    
    private let tapBuffer: AudioRingBuffer
    private let micBuffer: AudioRingBuffer
    
    private var pollingTask: Task<Void, Never>?
    
    init(sessionID: UUID, tapBuffer: AudioRingBuffer, micBuffer: AudioRingBuffer) throws {
        self.tapBuffer = tapBuffer
        self.micBuffer = micBuffer
        
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let basePath = appSupport.appendingPathComponent("Atrium/Sessions/\(sessionID.uuidString)")
        
        try FileManager.default.createDirectory(at: basePath, withIntermediateDirectories: true)
        
        let tracksPath = basePath.appendingPathComponent("tracks")
        try FileManager.default.createDirectory(at: tracksPath, withIntermediateDirectories: true)
        
        self.sessionURL = basePath
        self.youTrackURL = tracksPath.appendingPathComponent("you.caf")
        self.themTrackURL = tracksPath.appendingPathComponent("them.caf")
        self.incompleteMarkerURL = basePath.appendingPathComponent("INCOMPLETE")
        self.m4aURL = basePath.appendingPathComponent("session.m4a")
        
        FileManager.default.createFile(atPath: incompleteMarkerURL.path, contents: nil, attributes: nil)
        
        let formatMic = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let formatTap = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        
        youFile = try AVAudioFile(forWriting: youTrackURL, settings: formatMic.settings)
        themFile = try AVAudioFile(forWriting: themTrackURL, settings: formatTap.settings)
    }
    
    func startPolling() {
        pollingTask = Task {
            while !Task.isCancelled {
                drainAvailable()
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            // Final drain: Task.sleep guarantees only a minimum delay, so a
            // backlog may remain when polling is cancelled.
            drainAvailable()
        }
    }
    
    /// Drains everything currently buffered, not a single fixed-size chunk.
    ///
    /// `Task.sleep` only guarantees a *minimum* delay, so ticks routinely run
    /// late and more than one 50ms chunk accumulates. Reading a fixed 2400
    /// frames per tick could never catch up, so the backlog grew until the
    /// ring buffer overflowed and silently discarded recorded audio.
    private func drainAvailable() {
        // 50ms chunks (48000 * 0.05 = 2400 frames), drained until exhausted.
        let chunkFrames = 2400

        while micBuffer.availableFrames >= chunkFrames,
              let micData = micBuffer.read(count: chunkFrames) {
            writeToAudioFile(file: youFile, data: micData, channels: 1)
        }
        while tapBuffer.availableFrames >= chunkFrames * 2,
              let tapData = tapBuffer.read(count: chunkFrames * 2) {
            writeToAudioFile(file: themFile, data: tapData, channels: 2)
        }
    }

    private func writeToAudioFile(file: AVAudioFile?, data: [Float], channels: AVAudioChannelCount) {
        guard let file = file, let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: channels) else { return }
        let frameCount = AVAudioFrameCount(data.count / Int(channels))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }
        
        buffer.frameLength = frameCount
        for ch in 0..<Int(channels) {
            let channelData = buffer.floatChannelData![ch]
            for frame in 0..<Int(frameCount) {
                channelData[frame] = data[frame * Int(channels) + ch]
            }
        }
        try? file.write(from: buffer)
    }
    
    /// Frames lost to ring-buffer overflow during the session. Non-zero means
    /// the recording has gaps.
    var droppedFrames: Int { micBuffer.totalDroppedFrames + tapBuffer.totalDroppedFrames }

    func stopAndFinalize() async throws {
        pollingTask?.cancel()

        let dropped = droppedFrames
        if dropped > 0 {
            logger.error("Recording dropped \(dropped) frames (~\(Double(dropped) / 48000.0)s) to ring-buffer overflow")
        }
        youFile = nil
        themFile = nil
        
        try await muxToM4A()
        
        if FileManager.default.fileExists(atPath: incompleteMarkerURL.path) {
            try FileManager.default.removeItem(at: incompleteMarkerURL)
        }
    }
    
    private func muxToM4A() async throws {
        let composition = AVMutableComposition()

        // Either side can be empty and the session is still worth keeping: a
        // failed system-audio tap must not discard a good microphone
        // recording, and vice versa.
        var mixedAny = false

        for url in [youTrackURL, themTrackURL] {
            let asset = AVURLAsset(url: url)
            guard let sourceTrack = try await asset.loadTracks(withMediaType: .audio).first else {
                logger.warning("No audio track in \(url.lastPathComponent); excluding it from the mix")
                continue
            }
            let duration = try await asset.load(.duration)
            guard duration.isValid, duration.seconds > 0 else {
                logger.warning("\(url.lastPathComponent) is empty; excluding it from the mix")
                continue
            }
            guard let compTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }

            try compTrack.insertTimeRange(CMTimeRange(start: .zero, duration: duration),
                                          of: sourceTrack,
                                          at: .zero)
            mixedAny = true
        }

        guard mixedAny else {
            throw SessionWriterError.noAudioCaptured
        }

        guard let exportSession = AVAssetExportSession(asset: composition,
                                                       presetName: AVAssetExportPresetAppleM4A) else {
            throw SessionWriterError.exportUnavailable
        }
        exportSession.outputURL = m4aURL
        exportSession.outputFileType = .m4a

        await exportSession.export()

        // Report export failures instead of leaving a missing file for a later
        // stage to trip over.
        if let error = exportSession.error {
            throw error
        }
        guard FileManager.default.fileExists(atPath: m4aURL.path) else {
            throw SessionWriterError.exportProducedNoFile
        }
    }
}
