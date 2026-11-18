import AVFoundation
import Foundation
import OSLog

/// Turns a recorded call folder into a transcript and compact audio.
///
/// Every step reads and writes only the folder, so a call can be processed
/// again at any time: after a crash, a failed model download, or with a
/// different model.
public final class CallProcessor: @unchecked Sendable {
    private let recognizer = SpeechRecognizer()
    private let logger = Logger(subsystem: "app.atrium", category: "CallProcessor")

    public init() {}

    /// Transcribes the call in `folder`, writes `transcript.md`, then replaces
    /// the raw tracks with `call.mp4`. `progress` runs from 0 to 1.
    @discardableResult
    public func process(_ folder: URL, model: String = SpeechRecognizer.configuredModel,
                        progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> Transcript {
        let errorURL = folder.appendingPathComponent(SessionFiles.error)
        do {
            let transcript = try await transcribe(folder, model: model, progress: progress)
            try? FileManager.default.removeItem(at: errorURL)
            do {
                try await compress(folder)
            } catch {
                // The transcript is safe; the raw tracks stay until this works.
                logger.error("Compressing audio failed: \(error.localizedDescription)")
            }
            return transcript
        } catch {
            try? error.localizedDescription.write(to: errorURL, atomically: true, encoding: .utf8)
            throw error
        }
    }

    private func transcribe(_ folder: URL, model: String,
                            progress: @escaping @Sendable (Double) -> Void) async throws -> Transcript {
        let tracks: [(Speaker, URL)] = [(.me, track(.me, in: folder)), (.them, track(.them, in: folder))]
            .compactMap { speaker, url in url.map { (speaker, $0) } }
        guard !tracks.isEmpty else { throw CocoaError(.fileNoSuchFile) }

        progress(0)
        try await recognizer.load(model: model)
        defer { recognizer.unload() }

        var results: [Speaker: [Utterance]] = [:]
        var failures: [Speaker: Error] = [:]
        for (index, (speaker, url)) in tracks.enumerated() {
            guard CallRecorder.duration(of: url) > 0 else { results[speaker] = []; continue }
            do {
                results[speaker] = try await recognizer.transcribe(url, speaker: speaker) { fraction in
                    progress((Double(index) + fraction) / Double(tracks.count))
                }
            } catch {
                logger.error("Transcribing \(speaker.rawValue) failed: \(error.localizedDescription)")
                failures[speaker] = error
            }
        }
        // Report the real error instead of "no speech" when nothing worked.
        if results.isEmpty, let error = failures.values.first { throw error }

        var warnings = failures.map { speaker, error in
            "The \(speaker.label.lowercased()) side could not be transcribed: \(error.localizedDescription)"
        }
        for speaker in [Speaker.me, .them] where track(speaker, in: folder) == nil {
            warnings.append("No \(speaker.label.lowercased()) audio was recorded.")
        }

        let duration = tracks.map { CallRecorder.duration(of: $0.1) }.max() ?? 0
        let session = SessionStore.session(at: folder)
        let transcript = Transcript(
            recordedAt: session?.createdAt ?? Date(),
            durationSeconds: duration,
            model: model,
            warnings: warnings.sorted(),
            utterances: TranscriptMerger.merge(me: results[.me] ?? [], them: results[.them] ?? []))

        let markdown = TranscriptRenderer.markdown(transcript, title: Self.title(for: transcript.recordedAt))
        try markdown.write(to: folder.appendingPathComponent(SessionFiles.transcriptMarkdown),
                           atomically: true, encoding: .utf8)
        progress(1)
        return transcript
    }

    /// Replaces the raw tracks (about 700 MB per hour each) with one mixed
    /// `call.mp4`. The raw files are deleted only once it exists and plays.
    private func compress(_ folder: URL) async throws {
        let raws = [SessionFiles.meRaw, SessionFiles.themRaw].map { folder.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        let sources = raws.filter { CallRecorder.duration(of: $0) > 0 }
        guard !sources.isEmpty else { return }
        try await AudioExport.mp4(mixing: sources, to: folder.appendingPathComponent(SessionFiles.audio))
        for raw in raws {
            try FileManager.default.removeItem(at: raw)
        }
    }

    /// One side's raw track, if it was recorded.
    func track(_ speaker: Speaker, in folder: URL) -> URL? {
        let url = folder.appendingPathComponent(speaker == .me ? SessionFiles.meRaw : SessionFiles.themRaw)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func title(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE d MMMM yyyy, HH:mm"
        return "Call — \(formatter.string(from: date))"
    }
}

enum AudioExport {
    enum Failure: LocalizedError {
        case unavailable, unplayable(String)
        var errorDescription: String? {
            switch self {
            case .unavailable: return "Could not create an audio export session."
            case .unplayable(let name): return "\(name) was written but is not playable."
            }
        }
    }

    /// Speech needs no more than this; it keeps an hour of call near 30 MB.
    static let bitRate = 64_000

    /// Mixes `sources` (all starting at zero) into one mono AAC `.mp4`.
    static func mp4(mixing sources: [URL], to destination: URL) async throws {
        let composition = AVMutableComposition()
        for url in sources {
            let asset = AVURLAsset(url: url)
            guard let track = try await asset.loadTracks(withMediaType: .audio).first else { continue }
            let duration = try await asset.load(.duration)
            let compositionTrack = composition.addMutableTrack(withMediaType: .audio,
                                                               preferredTrackID: kCMPersistentTrackID_Invalid)
            try compositionTrack?.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: track, at: .zero)
        }
        let tracks = composition.tracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw Failure.unavailable }

        let reader = try AVAssetReader(asset: composition)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        reader.add(output)

        try? FileManager.default.removeItem(at: destination)
        let writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: bitRate,
        ])
        input.expectsMediaDataInRealTime = false
        writer.add(input)
        guard reader.startReading(), writer.startWriting() else {
            throw reader.error ?? writer.error ?? Failure.unavailable
        }
        writer.startSession(atSourceTime: .zero)

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var finished = false
            input.requestMediaDataWhenReady(on: DispatchQueue(label: "app.atrium.export")) {
                while !finished, input.isReadyForMoreMediaData {
                    if let buffer = output.copyNextSampleBuffer(), input.append(buffer) { continue }
                    finished = true
                    input.markAsFinished()
                    continuation.resume()
                }
            }
        }
        await writer.finishWriting()
        guard reader.status == .completed, writer.status == .completed else {
            throw reader.error ?? writer.error ?? Failure.unplayable(destination.lastPathComponent)
        }
        let duration = try await AVURLAsset(url: destination).load(.duration)
        guard duration.isValid, duration.seconds > 0 else { throw Failure.unplayable(destination.lastPathComponent) }
    }
}
