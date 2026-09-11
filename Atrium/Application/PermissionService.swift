import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreGraphics
import AppKit
import OSLog

enum PermissionStatus {
    case granted, denied, undetermined
}

final class PermissionService {
    private static let logger = Logger(subsystem: "app.atrium.app", category: "PermissionService")
    
    static func checkMicrophone() async -> PermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            return granted ? .granted : .denied
        @unknown default: return .denied
        }
    }
    
    /// Whether screen-recording consent has been granted.
    ///
    /// CoreAudio process taps are gated by this same consent. Without it the
    /// tap still starts and delivers buffers — they are just silent — so this
    /// must be checked explicitly rather than relying on a capture error.
    static func hasScreenCapturePermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Prompts for screen-recording access if it has not been decided yet.
    ///
    /// macOS only shows this prompt once per app identity; afterwards the user
    /// must change it in System Settings.
    @discardableResult
    static func requestScreenCapturePermission() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        logger.info("Requesting screen recording access for system-audio capture")
        return CGRequestScreenCaptureAccess()
    }

    static func openScreenRecordingSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    static func checkScreenCapture() async -> Bool {
        // SCK doesn't have a simple permission check. Attempting to get shareable
        // content will trigger the permission dialog if not yet granted, or throw
        // if denied.
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            return true
        } catch {
            logger.warning("Screen capture permission check failed: \(error.localizedDescription)")
            return false
        }
    }
}
