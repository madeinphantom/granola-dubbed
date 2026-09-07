import Foundation
import SwiftData

enum MeetingState: String, Codable {
    case recording
    case processing
    case ready
    case failed
}

@Model
final class Meeting {
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    var title: String
    var calendarEventIdentifier: String?
    var stateRaw: String
    var duration: TimeInterval
    var audioMixRelativePath: String
    var youTrackRelativePath: String
    var themTrackRelativePath: String
    var transcriptJSONPath: String?
    var notesMarkdown: String
    var modelRevision: String
    @Relationship(deleteRule: .cascade) var speakers: [Speaker]
    
    var state: MeetingState {
        get { MeetingState(rawValue: stateRaw) ?? .failed }
        set { stateRaw = newValue.rawValue }
    }
    
    init(id: UUID = UUID(), createdAt: Date = Date(), title: String = "New Meeting", state: MeetingState = .recording, duration: TimeInterval = 0, audioMixRelativePath: String = "", youTrackRelativePath: String = "", themTrackRelativePath: String = "", notesMarkdown: String = "", modelRevision: String = "1.0", speakers: [Speaker] = []) {
        self.id = id
        self.createdAt = createdAt
        self.title = title
        self.stateRaw = state.rawValue
        self.duration = duration
        self.audioMixRelativePath = audioMixRelativePath
        self.youTrackRelativePath = youTrackRelativePath
        self.themTrackRelativePath = themTrackRelativePath
        self.notesMarkdown = notesMarkdown
        self.modelRevision = modelRevision
        self.speakers = speakers
    }
}

@Model
final class Speaker {
    var id: UUID
    var label: String
    var isLocalUser: Bool
    var colorHex: String
    var embedding: Data?
    
    init(id: UUID = UUID(), label: String, isLocalUser: Bool = false, colorHex: String = "#FF0000", embedding: Data? = nil) {
        self.id = id
        self.label = label
        self.isLocalUser = isLocalUser
        self.colorHex = colorHex
        self.embedding = embedding
    }
}

struct TranscriptDocument: Codable {
    var version: Int
    var language: String
    var segments: [TranscriptSegment]
}

struct TranscriptSegment: Codable, Identifiable {
    var id: UUID
    var speakerId: UUID
    var start: TimeInterval
    var end: TimeInterval
    var text: String
    var words: [TranscriptWord]
    var isOverlap: Bool
}

struct TranscriptWord: Codable {
    var start: TimeInterval
    var end: TimeInterval
    var text: String
    var probability: Float
}
