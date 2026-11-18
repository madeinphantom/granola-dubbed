import Foundation

/// File names inside one call's folder. The folder is the whole record of a
/// call; there is no database. A finished call is exactly two files: the
/// audio and the transcript, both named after the folder (the call's title)
/// so a file still says which call it is once moved, attached or found by
/// Spotlight. A file under another name is still found, so a rename that was
/// interrupted loses nothing.
public enum SessionFiles {
    public static func transcript(in folder: URL) -> URL {
        existing(in: folder, extension: "md") ?? named(after: folder, extension: "md")
    }
    /// Both sides mixed. `.mp4` rather than `.m4a`, which macOS opens in Music.
    public static func audio(in folder: URL) -> URL {
        existing(in: folder, extension: "mp4") ?? named(after: folder, extension: "mp4")
    }
    /// Raw tracks, kept until the transcript and the audio exist.
    public static let meRaw = "me.caf"
    public static let themRaw = "them.caf"
    public static let error = "transcription-error.txt"

    static func named(after folder: URL, extension ext: String) -> URL {
        folder.appendingPathComponent(folder.lastPathComponent).appendingPathExtension(ext)
    }

    static func existing(in folder: URL, extension ext: String) -> URL? {
        (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))?
            .first { $0.pathExtension == ext }
    }
}

public struct Session: Identifiable, Hashable, Sendable {
    public enum State: Sendable, Hashable {
        case transcribed
        /// Audio exists but there is no transcript yet (still queued, failed,
        /// or the app quit before it finished).
        case untranscribed(error: String?)
    }

    public let folder: URL
    /// What the call was about, once it has been named; nil while it still
    /// has its date name.
    public let title: String?
    public let createdAt: Date
    public let state: State
    public var id: URL { folder }

    public var transcriptURL: URL { SessionFiles.transcript(in: folder) }
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
        unusedFolder(named: folderFormatter.string(from: date), in: root)
    }

    private static func unusedFolder(named base: String, in root: URL) -> URL {
        var candidate = root.appendingPathComponent(base, isDirectory: true)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = root.appendingPathComponent("\(base) (\(suffix))", isDirectory: true)
            suffix += 1
        }
        return canonical(candidate)
    }

    /// Renames a call after its title: the folder, then both files. Returns
    /// the call's new folder.
    public static func rename(_ folder: URL, to title: String) throws -> URL {
        let folder = canonical(folder)
        guard folder.lastPathComponent != title else { return folder }
        let target = unusedFolder(named: title, in: folder.deletingLastPathComponent())
        try FileManager.default.moveItem(at: folder, to: target)
        for ext in ["md", "mp4"] {
            let wanted = SessionFiles.named(after: target, extension: ext)
            if let current = SessionFiles.existing(in: target, extension: ext), current != wanted {
                try FileManager.default.moveItem(at: current, to: wanted)
            }
        }
        return target
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
        if fm.fileExists(atPath: SessionFiles.transcript(in: folder).path) {
            state = .transcribed
        } else if has(SessionFiles.meRaw) || has(SessionFiles.themRaw) {
            let error = try? String(contentsOf: folder.appendingPathComponent(SessionFiles.error), encoding: .utf8)
            state = .untranscribed(error: error?.trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            return nil
        }
        let name = folder.lastPathComponent.replacingOccurrences(of: #" \(\d+\)$"#, with: "",
                                                                  options: .regularExpression)
        let dated = folderFormatter.date(from: name)
        // A named call keeps its folder's creation date: moving a folder keeps it.
        let created = dated
            ?? (try? folder.resourceValues(forKeys: [.creationDateKey]).creationDate)
            ?? .distantPast
        return Session(folder: folder, title: dated == nil ? name : nil, createdAt: created, state: state)
    }

    /// Calls in `root`, newest first.
    public static func sessions(in root: URL = root) -> [Session] {
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return folders.compactMap(session(at:)).sorted { $0.createdAt > $1.createdAt }
    }
}

