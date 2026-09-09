import Foundation
import Sparkle
import SwiftUI

/// Wraps Sparkle so SwiftUI can drive it.
///
/// `SPUStandardUpdaterController` owns the whole update lifecycle; this exposes
/// just enough for a menu item to bind to.
@MainActor
final class UpdaterService: ObservableObject {
    static let shared = UpdaterService()

    private let controller: SPUStandardUpdaterController

    /// Mirrors Sparkle's own readiness so the menu item disables itself while
    /// a check is already running.
    @Published var canCheckForUpdates = false

    /// Whether Sparkle checks automatically. Persisted by Sparkle itself, so it
    /// is read through the updater rather than a separate UserDefaults key.
    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    private init() {
        controller = SPUStandardUpdaterController(startingUpdater: true,
                                                  updaterDelegate: nil,
                                                  userDriverDelegate: nil)
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }

    /// Version string shown in Settings, e.g. "0.3.0 (3)".
    var currentVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(short) (\(build))"
    }

    var lastUpdateCheckDate: Date? {
        controller.updater.lastUpdateCheckDate
    }
}
