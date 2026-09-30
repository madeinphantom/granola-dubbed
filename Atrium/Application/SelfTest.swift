import AVFoundation
import AppKit
import Foundation
import OSLog

/// End-to-end check of the real recording pipeline, run inside the installed
/// app so it uses Atrium's own microphone and Screen Recording grants.
///
/// Launch with: `open -a Atrium --args --selftest /path/to/report.json`
///
/// It records while macOS speaks a known phrase through the speakers, stops,
/// transcribes, writes a JSON report, deletes the test recording, and quits.
/// Every earlier release shipped without one real recording ever being
/// exercised; this makes that check a single command.
@MainActor
enum SelfTest {
    static let phrase = "Atrium self test. The quick brown fox jumps over the lazy dog."
    private static let logger = Logger(subsystem: "app.atrium.app", category: "SelfTest")

    /// Report path when launched with `--selftest <path>`.
    static var requestedReportURL: URL? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--selftest"), i + 1 < args.count else { return nil }
        return URL(fileURLWithPath: args[i + 1])
    }

    struct TrackReport: Codable {
        var durationSeconds: Double
        var rms: Double
    }

    struct Report: Codable {
        var version: String
        var screenRecordingGranted: Bool
        var systemAudioUnavailable: Bool
        var finalState: String
        var lastError: String?
        var you: TrackReport?
        var them: TrackReport?
        var micAuthorization: String
        var micFramesReceived: Int?
        var micInputFormat: String?
        var systemCallbacksReceived: Int?
        var transcript: String
        var passed: Bool
        var failures: [String]
    }

    static func run(controller: SessionController, reportURL: URL) async {
        var failures: [String] = []

        await controller.startRecording()
        guard let meeting = controller.activeMeeting else {
            write(Report(version: appVersion,
                         screenRecordingGranted: PermissionService.hasScreenCapturePermission(),
                         systemAudioUnavailable: controller.systemAudioUnavailable,
                         finalState: "not-started",
                         lastError: controller.lastError,
                         you: nil, them: nil,
                         micAuthorization: micAuthorization,
                         micFramesReceived: nil, micInputFormat: nil, systemCallbacksReceived: nil,
                         transcript: "",
                         passed: false,
                         failures: ["Recording did not start: \(controller.lastError ?? "unknown")"]),
                  to: reportURL)
            NSApp.terminate(nil)
            return
        }

        let session = controller.activeSession
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        await speak(phrase)
        try? await Task.sleep(nanoseconds: 1_500_000_000)

        await controller.stopRecordingAndTranscribe()

        let dir = Preferences.shared.sessionsDirectory.appendingPathComponent(meeting.id.uuidString)
        let you = measure(dir.appendingPathComponent("tracks/you.caf"))
        let them = measure(dir.appendingPathComponent("tracks/them.caf"))
        let transcript = AudioStore.shared.loadTranscript(for: meeting)?
            .segments.map(\.text).joined(separator: " ") ?? ""

        if meeting.state != .ready { failures.append("Meeting ended in state \(meeting.state.rawValue)") }
        if (session?.micFramesReceived ?? 0) == 0 { failures.append("Microphone delivered no frames (authorization: \(micAuthorization))") }
        if controller.systemAudioUnavailable { failures.append("System audio unavailable (Screen Recording not granted)") }
        if let them, let you {
            if them.rms < 0.001 { failures.append("them.caf is silent (rms \(them.rms))") }
            let longer = max(you.durationSeconds, them.durationSeconds)
            if longer > 0, abs(you.durationSeconds - them.durationSeconds) / longer > 0.15 {
                failures.append("Track durations disagree: you \(you.durationSeconds)s vs them \(them.durationSeconds)s")
            }
        } else {
            failures.append("Missing track file")
        }
        let heard = transcript.lowercased()
        if !["fox", "lazy", "dog", "quick"].contains(where: heard.contains) {
            failures.append("Transcript did not contain the spoken phrase")
        }

        write(Report(version: appVersion,
                     screenRecordingGranted: PermissionService.hasScreenCapturePermission(),
                     systemAudioUnavailable: controller.systemAudioUnavailable,
                     finalState: meeting.state.rawValue,
                     lastError: controller.lastError,
                     you: you, them: them,
                     micAuthorization: micAuthorization,
                     micFramesReceived: session?.micFramesReceived,
                     micInputFormat: session?.micInputFormatDescription,
                     systemCallbacksReceived: session?.systemCallbacksReceived,
                     transcript: transcript,
                     passed: failures.isEmpty,
                     failures: failures),
              to: reportURL)

        // A self-test must not leave a recording of the room behind.
        AudioStore.shared.delete(meeting: meeting)
        NSApp.terminate(nil)
    }

    private static var micAuthorization: String {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "notDetermined"
        @unknown default: return "unknown"
        }
    }

    private static var appVersion: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }

    private static func speak(_ text: String) async {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            process.arguments = [text]
            process.terminationHandler = { _ in continuation.resume() }
            do {
                try process.run()
            } catch {
                logger.error("Could not run say: \(error.localizedDescription)")
                continuation.resume()
            }
        }
    }

    private static func measure(_ url: URL) -> TrackReport? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        let duration = Double(file.length) / format.sampleRate
        guard file.length > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil,
              let channels = buffer.floatChannelData else {
            return TrackReport(durationSeconds: duration, rms: 0)
        }
        var sum = 0.0
        var count = 0
        for ch in 0..<Int(format.channelCount) {
            let samples = channels[ch]
            for i in 0..<Int(buffer.frameLength) {
                let v = Double(samples[i])
                sum += v * v
            }
            count += Int(buffer.frameLength)
        }
        return TrackReport(durationSeconds: duration, rms: count > 0 ? (sum / Double(count)).squareRoot() : 0)
    }

    private static func write(_ report: Report, to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(report) {
            try? data.write(to: url)
        }
    }
}
