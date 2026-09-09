import Foundation
import SwiftUI

/// User-configurable settings, backed by `UserDefaults`.
///
/// Keys are declared once here so the Settings UI and the audio pipeline cannot
/// drift apart.
enum PreferenceKey {
    static let speakerSensitivity = "speakerSensitivity"
    static let whisperModel = "whisperModel"
    static let launchAtLogin = "launchAtLogin"
    static let menuBarOnly = "menuBarOnly"
    static let confirmBeforeDelete = "confirmBeforeDelete"
}

enum WhisperModel: String, CaseIterable, Identifiable {
    case tiny = "openai_whisper-tiny"
    case base = "openai_whisper-base"
    case small = "openai_whisper-small"
    case largeTurbo = "openai_whisper-large-v3_turbo"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .tiny: return "Tiny — fastest, least accurate"
        case .base: return "Base"
        case .small: return "Small"
        case .largeTurbo: return "Large v3 Turbo — most accurate"
        }
    }

    var approximateDownloadSize: String {
        switch self {
        case .tiny: return "~75 MB"
        case .base: return "~145 MB"
        case .small: return "~480 MB"
        case .largeTurbo: return "~950 MB"
        }
    }
}

@MainActor
final class Preferences: ObservableObject {
    static let shared = Preferences()

    /// RMS energy above which a track counts as active speech.
    ///
    /// Exposed because the correct value depends on microphone gain and call
    /// volume; the original hardcoded 0.01 was never validated against a real
    /// call. Lower catches quiet speakers but picks up background noise.
    @AppStorage(PreferenceKey.speakerSensitivity) var speakerSensitivity: Double = 0.01

    @AppStorage(PreferenceKey.whisperModel) var whisperModelRaw: String = WhisperModel.largeTurbo.rawValue

    @AppStorage(PreferenceKey.menuBarOnly) var menuBarOnly: Bool = false

    @AppStorage(PreferenceKey.confirmBeforeDelete) var confirmBeforeDelete: Bool = true

    var whisperModel: WhisperModel {
        WhisperModel(rawValue: whisperModelRaw) ?? .largeTurbo
    }

    /// Root directory holding every recorded session.
    var sessionsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("Atrium/Sessions", isDirectory: true)
    }

    /// Total bytes used by all recordings.
    func totalStorageBytes() -> Int64 {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: sessionsDirectory,
                                    includingPropertiesForKeys: [.totalFileAllocatedSizeKey],
                                    options: [.skipsHiddenFiles]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in e {
            let size = (try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize
            total += Int64(size ?? 0)
        }
        return total
    }
}
