import Foundation
import SwiftData

@MainActor
final class AudioStore: ObservableObject {
    static let shared = AudioStore()
    
    let container: ModelContainer
    
    init() {
        do {
            let config = ModelConfiguration(isStoredInMemoryOnly: false)
            container = try ModelContainer(for: Meeting.self, Speaker.self, configurations: config)
        } catch {
            fatalError("Failed to initialize ModelContainer: \(error.localizedDescription)")
        }
    }
    
    func delete(meeting: Meeting) {
        // Delete audio files from disk.
        //
        // Derive the directory from the meeting id rather than from
        // audioMixRelativePath: that property defaults to "", and
        // "Atrium/" + "" then deletingLastPathComponent() resolves to
        // Application Support itself — deleting every app's data on the Mac.
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let sessionsRoot = appSupport.appendingPathComponent("Atrium/Sessions", isDirectory: true)
        let sessionDir = sessionsRoot.appendingPathComponent(meeting.id.uuidString, isDirectory: true)

        // Belt and braces: never remove anything that is not a session directory.
        let isInsideSessions = sessionDir.standardizedFileURL.path
            .hasPrefix(sessionsRoot.standardizedFileURL.path + "/")

        if isInsideSessions, FileManager.default.fileExists(atPath: sessionDir.path) {
            try? FileManager.default.removeItem(at: sessionDir)
        }
        
        container.mainContext.delete(meeting)
        try? container.mainContext.save()
    }
    
    func loadTranscript(for meeting: Meeting) -> TranscriptDocument? {
        guard let path = meeting.transcriptJSONPath else { return nil }
        let url = URL(fileURLWithPath: path)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(TranscriptDocument.self, from: data)
    }
}
