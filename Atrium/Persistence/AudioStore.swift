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
        // Delete audio files from disk
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let sessionDir = appSupport.appendingPathComponent("Atrium/\(meeting.audioMixRelativePath)").deletingLastPathComponent()
        
        if FileManager.default.fileExists(atPath: sessionDir.path) {
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
