import Foundation

/// File names inside one call's folder. The folder is the whole record of a
/// call; there is no database.
public enum SessionFiles {
    public static let transcriptMarkdown = "transcript.md"
    public static let transcriptJSON = "transcript.json"
    public static let mix = "call.m4a"
    /// Raw tracks, kept until the transcript and compressed audio exist.
    public static let meRaw = "me.caf"
    public static let themRaw = "them.caf"
    /// Compressed tracks kept after transcription, for listening or redoing it.
    public static let meCompressed = "me.m4a"
    public static let themCompressed = "them.m4a"
    public static let error = "transcription-error.txt"
}

public struct Session: Identifiable, Hashable, Sendable {
    public enum State: Sendable, Hashable {
        case transcribed
        /// Audio exists but there is no transcript yet (still queued, failed,
        /// or the app quit before it finished).
        case untranscribed(error: String?)
    }

    public let folder: URL
    public let createdAt: Date
    public let state: State
    public var id: URL { folder }

    public var transcriptURL: URL { folder.appendingPathComponent(SessionFiles.transcriptMarkdown) }
}

public enum SessionStore {
    /// `~/Documents/Atrium` unless overridden with
    /// `defaults write app.atrium.mac RecordingsDirectory /some/path`.
    public static var root: URL {
        if let custom = UserDefaults.standard.string(forKey: "RecordingsDirectory"), !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
        }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("Atrium", isDirectory: true)
    }

    private static let folderFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        // Same shape as macOS screenshot names; Finder sorts it by time.
        formatter.dateFormat = "'Call' yyyy-MM-dd 'at' HH.mm.ss"
        return formatter
    }()

    /// A new, unused folder for a call starting at `date`.
    public static func newSessionFolder(at date: Date = Date(), in root: URL = root) -> URL {
        let base = folderFormatter.string(from: date)
        var candidate = root.appendingPathComponent(base, isDirectory: true)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = root.appendingPathComponent("\(base) (\(suffix))", isDirectory: true)
            suffix += 1
        }
        return canonical(candidate)
    }

    /// One spelling per folder, so URLs from different sources compare equal
    /// (`/var` vs `/private/var`, with or without a trailing slash).
    public static func canonical(_ folder: URL) -> URL {
        URL(fileURLWithPath: folder.resolvingSymlinksInPath().path, isDirectory: true)
    }

    public static func session(at folder: URL) -> Session? {
        let folder = canonical(folder)
        let fm = FileManager.default
        let has = { (name: String) in fm.fileExists(atPath: folder.appendingPathComponent(name).path) }
        let state: Session.State
        if has(SessionFiles.transcriptMarkdown) {
            state = .transcribed
        } else if has(SessionFiles.meRaw) || has(SessionFiles.themRaw)
                    || has(SessionFiles.meCompressed) || has(SessionFiles.themCompressed) {
            let error = try? String(contentsOf: folder.appendingPathComponent(SessionFiles.error), encoding: .utf8)
            state = .untranscribed(error: error?.trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            return nil
        }
        let name = folder.lastPathComponent
        let datePart = name.replacingOccurrences(of: #" \(\d+\)$"#, with: "", options: .regularExpression)
        let created = folderFormatter.date(from: datePart)
            ?? (try? folder.resourceValues(forKeys: [.creationDateKey]).creationDate)
            ?? .distantPast
        return Session(folder: folder, createdAt: created, state: state)
    }

    /// Calls in `root`, newest first.
    public static func sessions(in root: URL = root) -> [Session] {
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return folders.compactMap(session(at:)).sorted { $0.createdAt > $1.createdAt }
    }
}

