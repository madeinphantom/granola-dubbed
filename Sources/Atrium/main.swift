import AppKit
import AtriumCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let controller = AppController()
    private var statusMenu: StatusMenu?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let reportURL = SelfTest.requestedReportURL {
            Task { await SelfTest.run(controller: controller, reportURL: reportURL) }
            return
        }
        statusMenu = StatusMenu(controller: controller)
        // Calls left untranscribed because Atrium quit mid-way are picked up
        // again. Ones that failed with an error wait for the user to retry.
        for session in SessionStore.sessions().reversed() {
            if case .untranscribed(error: nil) = session.state { controller.enqueue(session.folder) }
        }
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    // Menu bar only: no Dock icon, no main window.
    app.setActivationPolicy(.accessory)
    app.run()
}
