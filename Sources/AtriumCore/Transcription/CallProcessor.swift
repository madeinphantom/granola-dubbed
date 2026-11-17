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

    /// Transcribes the call in `folder` and writes `transcript.md` and
    /// `transcript.json`. `progress` runs from 0 to 1.
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

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(transcript).write(to: folder.appendingPathComponent(SessionFiles.transcriptJSON),
                                             options: .atomic)
        let markdown = TranscriptRenderer.markdown(transcript, title: Self.title(for: transcript.recordedAt))
        try markdown.write(to: folder.appendingPathComponent(SessionFiles.transcriptMarkdown),
                           atomically: true, encoding: .utf8)
        progress(1)
        return transcript
    }

    /// Replaces the raw tracks (about 700 MB per hour each) with AAC copies
    /// and a single mixed `call.m4a` for listening. The raw files are deleted
    /// only once every compressed file exists and plays.
    private func compress(_ folder: URL) async throws {
        let meRaw = folder.appendingPathComponent(SessionFiles.meRaw)
        let themRaw = folder.appendingPathComponent(SessionFiles.themRaw)
        let raws = [meRaw, themRaw].filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !raws.isEmpty else { return }

        let outputs: [(sources: [URL], destination: URL)] = [
            ([meRaw], folder.appendingPathComponent(SessionFiles.meCompressed)),
            ([themRaw], folder.appendingPathComponent(SessionFiles.themCompressed)),
            ([meRaw, themRaw], folder.appendingPathComponent(SessionFiles.mix)),
        ]
        for output in outputs {
            let sources = output.sources.filter { CallRecorder.duration(of: $0) > 0 }
            guard !sources.isEmpty else { continue }
            try await AudioExport.m4a(mixing: sources, to: output.destination)
        }
        for raw in raws {
            try FileManager.default.removeItem(at: raw)
        }
    }

    /// The best available audio for one side: the raw track, else its AAC copy.
    func track(_ speaker: Speaker, in folder: URL) -> URL? {
        let names = speaker == .me
            ? [SessionFiles.meRaw, SessionFiles.meCompressed]
            : [SessionFiles.themRaw, SessionFiles.themCompressed]
        return names.map { folder.appendingPathComponent($0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
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

    /// Mixes `sources` (all starting at zero) into one AAC file.
    static func m4a(mixing sources: [URL], to destination: URL) async throws {
        let composition = AVMutableComposition()
        for url in sources {
            let asset = AVURLAsset(url: url)
            guard let track = try await asset.loadTracks(withMediaType: .audio).first else { continue }
            let duration = try await asset.load(.duration)
            let compositionTrack = composition.addMutableTrack(withMediaType: .audio,
                                                               preferredTrackID: kCMPersistentTrackID_Invalid)
            try compositionTrack?.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: track, at: .zero)
        }
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw Failure.unavailable
        }
        try? FileManager.default.removeItem(at: destination)
        try await session.export(to: destination, as: .m4a)
        let duration = try await AVURLAsset(url: destination).load(.duration)
        guard duration.isValid, duration.seconds > 0 else { throw Failure.unplayable(destination.lastPathComponent) }
    }
}

