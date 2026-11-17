import AppKit
import AVFoundation
import CoreGraphics

/// Microphone and system-audio consent, checked before every recording.
enum Permissions {
    enum Problem {
        case microphone
        /// CoreAudio process taps are gated by Screen & System Audio Recording
        /// consent. Without it the tap still runs but delivers silence, so it
        /// must be checked up front rather than detected from an error.
        case systemAudio
    }

    @MainActor
    static func check() async -> Problem? {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .audio) else { return .microphone }
        default: return .microphone
        }
        if !CGPreflightScreenCaptureAccess() {
            // Shows the system prompt the first time; macOS only applies a new
            // grant after the app relaunches, so this still reports a problem.
            CGRequestScreenCaptureAccess()
            return .systemAudio
        }
        return nil
    }

    @MainActor
    static func explain(_ problem: Problem) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        switch problem {
        case .microphone:
            alert.messageText = "Atrium needs your microphone"
            alert.informativeText = "Turn on Atrium in System Settings › Privacy & Security › Microphone."
        case .systemAudio:
            alert.messageText = "Atrium needs to hear the call"
            alert.informativeText = """
                Turn on Atrium in System Settings › Privacy & Security › Screen & System Audio Recording, \
                then quit and reopen Atrium. Atrium only records audio, never your screen.
                """
        }
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let anchor = problem == .microphone ? "Privacy_Microphone" : "Privacy_ScreenCapture"
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}

