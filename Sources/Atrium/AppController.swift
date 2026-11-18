import AppKit
import AtriumCore
import OSLog

/// Owns the one thing Atrium does: record a call, then transcribe it.
///
/// Recording and transcription are independent. A finished call joins a
/// queue and is transcribed in the background, so a second call can start
/// while the first is still being transcribed.
@MainActor
final class AppController {
    enum RecordingState {
        case idle
        case starting
        case recording(CallRecorder, since: Date)
    }

    private(set) var recording: RecordingState = .idle
    private(set) var transcribing: URL?
    private(set) var transcriptionProgress = 0.0
    private(set) var queued: [URL] = []
    /// Stats of the last stopped recording, for the self-test.
    private(set) var lastStats: RecordingStats?
    /// Where calls went when they were named after transcription.
    private var renamed: [URL: URL] = [:]

    var onChange: () -> Void = {}

    private let processor = CallProcessor()
    private let logger = Logger(subsystem: "app.atrium", category: "AppController")

    var isRecording: Bool {
        if case .recording = recording { return true }
        return false
    }

    func toggle() {
        switch recording {
        case .idle: Task { await start() }
        case .recording: stop()
        case .starting: break
        }
    }

    /// Returns the call's folder, or nil if recording could not start.
    @discardableResult
    func start(in root: URL = SessionStore.root, showingErrors: Bool = true) async -> URL? {
        guard case .idle = recording else { return nil }
        recording = .starting
        onChange()

        if let problem = await Permissions.check() {
            recording = .idle
            onChange()
            if showingErrors { Permissions.explain(problem) }
            return nil
        }

        let recorder = CallRecorder(directory: SessionStore.newSessionFolder(in: root))
        do {
            try recorder.start()
            recording = .recording(recorder, since: Date())
            onChange()
            return recorder.directory
        } catch {
            logger.error("Could not start: \(error.localizedDescription)")
            recording = .idle
            onChange()
            if showingErrors { Self.alert("Could not start recording", error.localizedDescription) }
            return nil
        }
    }

    func stop() {
        guard case .recording(let recorder, _) = recording else { return }
        recording = .idle
        do {
            lastStats = try recorder.stop()
            enqueue(recorder.directory)
        } catch {
            logger.error("Could not save: \(error.localizedDescription)")
            Self.alert("The recording could not be saved", error.localizedDescription)
        }
        onChange()
    }

    func enqueue(_ folder: URL) {
        let folder = SessionStore.canonical(folder)
        guard transcribing != folder, !queued.contains(folder) else { return }
        queued.append(folder)
        onChange()
        if transcribing == nil { Task { await drainQueue() } }
    }

    /// The folder a call is in now; naming it moves it.
    func currentFolder(of folder: URL) -> URL {
        renamed[SessionStore.canonical(folder)] ?? folder
    }

    /// Resolves once `folder` has been transcribed or has failed.
    func waitUntilProcessed(_ folder: URL) async {
        while transcribing == folder || queued.contains(folder) {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    private func drainQueue() async {
        while !queued.isEmpty {
            let folder = queued.removeFirst()
            transcribing = folder
            transcriptionProgress = 0
            onChange()
            do {
                let named = try await processor.process(folder) { fraction in
                    Task { @MainActor in
                        self.transcriptionProgress = fraction
                        self.onChange()
                    }
                }
                if named != folder { renamed[folder] = named }
            } catch {
                // The error is also written into the call's folder and shown
                // in the menu, where the call can be retried.
                logger.error("Transcription failed: \(error.localizedDescription)")
            }
            transcribing = nil
            onChange()
        }
    }

    static func alert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
