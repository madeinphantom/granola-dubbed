import Foundation
import SwiftData
import Combine
import OSLog

@MainActor
final class SessionController: ObservableObject {
    private let logger = Logger(subsystem: "app.atrium.app", category: "SessionController")
    
    enum RecordingError: LocalizedError {
        case microphoneDenied
        case alreadyRecording
        
        var errorDescription: String? {
            switch self {
            case .microphoneDenied: return "Microphone access is required. Grant it in System Settings > Privacy & Security > Microphone."
            case .alreadyRecording: return "A recording is already in progress."
            }
        }
    }
    
    @Published var activeSession: DualCaptureSession?
    @Published var activeMeeting: Meeting?
    @Published var isRecording: Bool = false
    @Published var isTranscribing: Bool = false
    @Published var transcriptionProgress: Float = 0.0
    @Published var lastError: String?
    
    let audioStore = AudioStore.shared
    private let asrEngine = ASREngine()
    private let dualChannelAssigner = DualChannelAssigner()
    private let transcriptAligner = TranscriptAligner()
    
    // Check for incomplete sessions on launch and mark them as failed
    func recoverIncompleteSessions() {
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
        guard activeSession == nil else {
            lastError = RecordingError.alreadyRecording.localizedDescription
            return
        }
        
        // Check permissions first
        let micStatus = await PermissionService.checkMicrophone()
        guard micStatus == .granted else {
            lastError = RecordingError.microphoneDenied.localizedDescription
            return
        }
        
        do {
            let session = DualCaptureSession()
            try session.start()
            
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
            self.lastError = nil
            
            RecPillWindowManager.shared.show()
            logger.info("Started recording session: \(session.sessionID)")
        } catch {
            lastError = "Failed to start capture: \(error.localizedDescription)"
            logger.error("Failed to start recording: \(error.localizedDescription)")
        }
    }
    
    func stopRecording() {
        guard let session = activeSession, let meeting = activeMeeting else { return }
        
        RecPillWindowManager.shared.hide()
        self.isRecording = false
        
        Task {
            await session.stop()
            meeting.state = .processing
            meeting.duration = Date().timeIntervalSince(meeting.createdAt)
            try? audioStore.container.mainContext.save()
            
            self.activeSession = nil
            self.isTranscribing = true
            
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let sessionDir = appSupport.appendingPathComponent("Atrium/Sessions/\(session.sessionID.uuidString)")
            let m4aPath = sessionDir.appendingPathComponent("session.m4a")
            let youPath = sessionDir.appendingPathComponent("tracks/you.caf")
            let themPath = sessionDir.appendingPathComponent("tracks/them.caf")
            let transcriptPath = sessionDir.appendingPathComponent("transcript.json")
            
            do {
                logger.info("Starting offline ASR pipeline")
                let rawSegments = try await asrEngine.transcribe(audioURL: m4aPath) { progress in
                    DispatchQueue.main.async {
                        self.transcriptionProgress = progress
                    }
                }
                
                let speakerTurns = try dualChannelAssigner.assign(youTrackURL: youPath, themTrackURL: themPath)
                
                let youSpeakerID = UUID()
                let themSpeakerID = UUID()
                
                let typedTurns: [(start: TimeInterval, end: TimeInterval, speakerId: UUID)] = speakerTurns.map { turn in
                    let id = turn.speaker == "You" ? youSpeakerID : themSpeakerID
                    return (start: turn.start, end: turn.end, speakerId: id)
                }
                
                let allWords = rawSegments.flatMap { $0.words }
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
            self.activeMeeting = nil
            try? audioStore.container.mainContext.save()
        }
    }
}
