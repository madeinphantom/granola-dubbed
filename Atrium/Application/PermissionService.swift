import Foundation
import AVFoundation
import ScreenCaptureKit
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
