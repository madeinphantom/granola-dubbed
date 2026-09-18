import Foundation
import SwiftData
import Combine
import OSLog
import AVFoundation

private enum TranscriptionPipelineError: LocalizedError {
    case noSpeechDetected

    var errorDescription: String? {
        "No speech was detected in the recording. Check that the audio tracks contain speech before retrying."
    }
}

@MainActor
final class SessionController: ObservableObject {
    private let logger = Logger(subsystem: "app.atrium.app", category: "SessionController")
    
    enum RecordingError: LocalizedError {
        case screenRecordingDenied
        case microphoneDenied
        case alreadyRecording
        
        var errorDescription: String? {
            switch self {
            case .microphoneDenied: return "Microphone access is required. Grant it in System Settings > Privacy & Security > Microphone."
            case .screenRecordingDenied: return "Recording your voice only — system audio needs Screen Recording access in System Settings > Privacy & Security."
            case .alreadyRecording: return "A recording is already in progress."
            }
        }
    }
    
    @Published var activeSession: DualCaptureSession?
    @Published var activeMeeting: Meeting?
    @Published var isStarting: Bool = false
    @Published var isRecording: Bool = false
    @Published var isFinalizing: Bool = false
    /// True when recording proceeded without system-audio capture.
    @Published var systemAudioUnavailable = false
    @Published var isTranscribing: Bool = false
    @Published var transcriptionProgress: Float = 0.0
    @Published var lastError: String?
    
    let audioStore = AudioStore.shared
    private let asrEngine = ASREngine()
    private let dualChannelAssigner = DualChannelAssigner()
    private let transcriptAligner = TranscriptAligner()
    
    // Check for incomplete sessions on launch and mark them as failed
    func recoverIncompleteSessions() {
        // A crash or failed export can leave a SwiftData row in an in-flight
        // state even if the marker was already removed. Keep it retryable.
        if let meetings = try? audioStore.container.mainContext.fetch(FetchDescriptor<Meeting>()) {
            for meeting in meetings where (meeting.state == .recording || meeting.state == .processing)
                && meeting.id != activeMeeting?.id {
                meeting.state = .failed
            }
            try? audioStore.container.mainContext.save()
        }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let sessionsDir = appSupport.appendingPathComponent("Atrium/Sessions")
        
        guard let contents = try? FileManager.default.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: nil) else { return }
        
        for dir in contents {
            let marker = dir.appendingPathComponent("INCOMPLETE")
            if FileManager.default.fileExists(atPath: marker.path) {
                logger.warning("Found incomplete session: \(dir.lastPathComponent)")
                // Clean up the marker — the meeting will show as "failed" in the UI
                try? FileManager.default.removeItem(at: marker)
                
                // Find and update the meeting in the database
                if let uuid = UUID(uuidString: dir.lastPathComponent) {
                    let descriptor = FetchDescriptor<Meeting>(predicate: #Predicate { $0.id == uuid })
                    if let meeting = try? audioStore.container.mainContext.fetch(descriptor).first {
                        meeting.state = .failed
                        try? audioStore.container.mainContext.save()
                    }
                }
            }
        }
    }
    
    func startRecording() async {
        guard activeSession == nil && !isStarting && !isFinalizing else {
            lastError = RecordingError.alreadyRecording.localizedDescription
            return
        }
        isStarting = true
        defer { isStarting = false }
        
        // Check permissions first
        let micStatus = await PermissionService.checkMicrophone()
        guard micStatus == .granted else {
            lastError = RecordingError.microphoneDenied.localizedDescription
            return
        }

        // System-audio capture is gated by screen-recording consent. Without
        // it the tap still runs but every sample is silent, which previously
        // produced recordings containing only the microphone with no warning.
        var canCaptureSystemAudio = PermissionService.hasScreenCapturePermission()
        if !canCaptureSystemAudio {
            PermissionService.requestScreenCapturePermission()
            canCaptureSystemAudio = PermissionService.hasScreenCapturePermission()
            if !canCaptureSystemAudio {
                systemAudioUnavailable = true
                lastError = RecordingError.screenRecordingDenied.localizedDescription
            }
        } else {
            systemAudioUnavailable = false
        }
        
        do {
            let session = DualCaptureSession()
            let capturedSystemAudio = try await session.start(captureSystemAudio: canCaptureSystemAudio)
            
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            let title = "Meeting · \(formatter.string(from: Date()))"
            
            let sessionDir = "Sessions/\(session.sessionID.uuidString)"
            
            let meeting = Meeting(
                id: session.sessionID,
                title: title,
                state: .recording,
                audioMixRelativePath: "\(sessionDir)/session.m4a",
                youTrackRelativePath: "\(sessionDir)/tracks/you.caf",
                themTrackRelativePath: "\(sessionDir)/tracks/them.caf"
            )
            audioStore.container.mainContext.insert(meeting)
            try audioStore.container.mainContext.save()
            
            self.activeSession = session
            self.activeMeeting = meeting
            self.isRecording = true
            self.systemAudioUnavailable = !capturedSystemAudio
            self.lastError = nil
            
            RecPillWindowManager.shared.show()
            logger.info("Started recording session: \(session.sessionID)")
        } catch {
            lastError = "Failed to start capture: \(error.localizedDescription)"
            logger.error("Failed to start recording: \(error.localizedDescription)")
        }
    }
    
    func stopRecording() {
        guard !isFinalizing, let session = activeSession, let meeting = activeMeeting else { return }
        
        RecPillWindowManager.shared.hide()
        self.isRecording = false
        self.isFinalizing = true
        
        Task {
            meeting.duration = Date().timeIntervalSince(meeting.createdAt)
            do {
                try await session.stop()
            } catch {
                meeting.state = .failed
                lastError = "Recording could not be saved: \(error.localizedDescription)"
                logger.error("Failed to finalize recording: \(error.localizedDescription)")
                activeSession = nil
                activeMeeting = nil
                isFinalizing = false
                try? audioStore.container.mainContext.save()
                return
            }
            meeting.state = .processing
            try? audioStore.container.mainContext.save()
            activeSession = nil
            isFinalizing = false
            await runTranscriptionPipeline(for: meeting, sessionID: session.sessionID)
        }
    }

    /// Re-runs transcription for an already-recorded session.
    ///
    /// Recordings whose audio survived but whose pipeline failed are worth
    /// salvaging rather than discarding — the audio cannot be recaptured.
    func retryTranscription(for meeting: Meeting) async {
        guard !isTranscribing else { return }
        meeting.state = .processing
        try? audioStore.container.mainContext.save()
        await runTranscriptionPipeline(for: meeting, sessionID: meeting.id)
    }

    private func runTranscriptionPipeline(for meeting: Meeting, sessionID: UUID) async {
            self.isTranscribing = true

            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let sessionDir = appSupport.appendingPathComponent("Atrium/Sessions/\(sessionID.uuidString)")
            let m4aPath = sessionDir.appendingPathComponent("session.m4a")
            let youPath = sessionDir.appendingPathComponent("tracks/you.caf")
            let themPath = sessionDir.appendingPathComponent("tracks/them.caf")
            let transcriptPath = sessionDir.appendingPathComponent("transcript.json")
            
            do {
                let duration = try? await AVURLAsset(url: m4aPath).load(.duration)
                if duration?.isValid != true || duration?.seconds.isFinite != true
                    || (duration?.seconds ?? 0) <= 0 {
                    if FileManager.default.fileExists(atPath: m4aPath.path) {
                        try FileManager.default.removeItem(at: m4aPath)
                    }
                    try await SessionWriter.rebuildMix(sessionID: sessionID)
                }
                logger.info("Starting offline ASR pipeline")
                asrEngine.modelOverride = Preferences.shared.whisperModel.rawValue
                let rawSegments = try await asrEngine.transcribe(audioURL: m4aPath) { progress in
                    DispatchQueue.main.async {
                        self.transcriptionProgress = progress
                    }
                }
                
                let speakerTurns = try dualChannelAssigner.assign(
                    youTrackURL: youPath,
                    themTrackURL: themPath,
                    energyThreshold: Float(Preferences.shared.speakerSensitivity)
                )
                
                let youSpeakerID = UUID()
                let themSpeakerID = UUID()
                
                let typedTurns: [(start: TimeInterval, end: TimeInterval, speakerId: UUID)] = speakerTurns.map { turn in
                    let id = turn.speaker == "You" ? youSpeakerID : themSpeakerID
                    return (start: turn.start, end: turn.end, speakerId: id)
                }
                
                // Some WhisperKit results have segment text but no word
                // timings. Preserve that text with segment-level timing so a
                // successful transcription cannot render as an empty page.
                let allWords = TranscriptAligner.timedUnits(from: rawSegments)
                guard !allWords.isEmpty else { throw TranscriptionPipelineError.noSpeechDetected }
                let alignedSegments = transcriptAligner.align(words: allWords,
                                                             speakerTurns: typedTurns,
                                                             fallbackSpeakerId: themSpeakerID)
                
                let transcriptDoc = TranscriptDocument(version: 1, language: "en", segments: alignedSegments)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(transcriptDoc)
                try data.write(to: transcriptPath)
                
                meeting.transcriptJSONPath = transcriptPath.path
                meeting.state = .ready
                
                let youSpeaker = Speaker(id: youSpeakerID, label: "You", isLocalUser: true, colorHex: "#FFFFFF")
                let themSpeaker = Speaker(id: themSpeakerID, label: "Them", isLocalUser: false, colorHex: "#888888")
                meeting.speakers = [youSpeaker, themSpeaker]
                
                logger.info("Pipeline completed. Segments: \(alignedSegments.count)")
            } catch {
                logger.error("Pipeline failed: \(error.localizedDescription)")
                meeting.state = .failed
                lastError = "Transcription failed: \(error.localizedDescription)"
            }
            
            self.isTranscribing = false
            self.transcriptionProgress = 0.0
            if self.activeMeeting?.id == meeting.id { self.activeMeeting = nil }
            try? audioStore.container.mainContext.save()
    }
}
