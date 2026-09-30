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
    static let toneHz = 1000.0
    static let toneSeconds = 3.0
    /// Loud, so it stands well above anything else playing on the Mac.
    static let toneAmplitude = 0.8
    /// Broken capture (wrong layout, dropped buffers) scores near 0 dB.
    static let minimumToneSNR = 15.0
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
        var systemInputFormat: String?
        var systemFramesWritten: Int?
        var systemFormatMismatches: Int?
        var systemConversionFailures: Int?
        var wallClockSeconds: Double?
        var toneHz: Double?
        var toneWindows: [ToneAnalysis]?
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
                         systemInputFormat: nil, systemFramesWritten: nil, systemFormatMismatches: nil,
                         systemConversionFailures: nil, wallClockSeconds: nil, toneHz: nil, toneWindows: nil,
                         transcript: "",
                         passed: false,
                         failures: ["Recording did not start: \(controller.lastError ?? "unknown")"]),
                  to: reportURL)
            NSApp.terminate(nil)
            return
        }

        let session = controller.activeSession
        let recordingStarted = Date()
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        await speak(phrase)
        try? await Task.sleep(nanoseconds: 500_000_000)

        // A pure tone proves system audio is clean, not just present: static
        // and wrong-rate capture are as loud as real audio and pass an RMS
        // check, but they cannot reproduce one clean frequency.
        let toneURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("atrium-selftest-tone.wav")
        var toneOffset: Double?
        do {
            try ToneAnalysis.writeTone(frequency: toneHz, seconds: toneSeconds,
                                       amplitude: Float(toneAmplitude), to: toneURL)
            toneOffset = Date().timeIntervalSince(recordingStarted)
            await run("/usr/bin/afplay", [toneURL.path])
        } catch {
            failures.append("Could not create the test tone: \(error.localizedDescription)")
        }
        try? await Task.sleep(nanoseconds: 1_000_000_000)

        let wallClock = Date().timeIntervalSince(recordingStarted)
        await controller.stopRecordingAndTranscribe()
        try? FileManager.default.removeItem(at: toneURL)

        let dir = Preferences.shared.sessionsDirectory.appendingPathComponent(meeting.id.uuidString)
        let you = measure(dir.appendingPathComponent("tracks/you.caf"))
        let them = measure(dir.appendingPathComponent("tracks/them.caf"))
        let transcript = AudioStore.shared.loadTranscript(for: meeting)?
            .segments.map(\.text).joined(separator: " ") ?? ""

        var toneWindows: [ToneAnalysis] = []
        if let toneOffset, let track = ToneAnalysis.monoSamples(of: dir.appendingPathComponent("tracks/them.caf")) {
            // Check the middle of the tone at several points, so intermittent
            // corruption fails too. Edges are skipped to absorb start latency.
            let window = Int(track.sampleRate * 0.3)
            for offset in stride(from: toneOffset + 0.6, through: toneOffset + toneSeconds - 0.9, by: 0.4) {
                let start = Int(offset * track.sampleRate)
                guard start >= 0, start + window <= track.samples.count else {
                    failures.append("them.caf ends before the test tone (\(String(format: "%.1f", offset))s)")
                    break
                }
                let analysis = ToneAnalysis.analyse(track.samples[start..<(start + window)],
                                                    sampleRate: track.sampleRate)
                    ?? ToneAnalysis(frequency: 0, snrDB: -999, amplitude: 0)
                toneWindows.append(analysis)
            }
            if toneWindows.contains(where: { abs($0.frequency - toneHz) > 5 }) {
                failures.append("Test tone came back at the wrong frequency (expected \(Int(toneHz)) Hz)")
            }
            if toneWindows.contains(where: { $0.snrDB < minimumToneSNR }) {
                failures.append("Test tone is not clean in them.caf (SNR below \(Int(minimumToneSNR)) dB): system audio has noise or static, or other audio was playing loudly")
            }
        } else if toneOffset != nil {
            failures.append("Could not read them.caf to check the test tone")
        }

        if meeting.state != .ready { failures.append("Meeting ended in state \(meeting.state.rawValue)") }
        if (session?.micFramesReceived ?? 0) == 0 { failures.append("Microphone delivered no frames (authorization: \(micAuthorization))") }
        if (session?.systemFormatMismatches ?? 0) > 0 {
            failures.append("\(session?.systemFormatMismatches ?? 0) system-audio callbacks did not match the tap format")
        }
        if (session?.systemConversionFailures ?? 0) > 0 {
            failures.append("\(session?.systemConversionFailures ?? 0) system-audio buffers failed conversion")
        }
        if controller.systemAudioUnavailable { failures.append("System audio unavailable (Screen Recording not granted)") }
        if let them, let you {
            if them.rms < 0.001 { failures.append("them.caf is silent (rms \(them.rms))") }
            let longer = max(you.durationSeconds, them.durationSeconds)
            if longer > 0, abs(you.durationSeconds - them.durationSeconds) / longer > 0.15 {
                failures.append("Track durations disagree: you \(you.durationSeconds)s vs them \(them.durationSeconds)s")
            }
            // Measured against the wall clock, not each other: a wrong sample
            // rate or extra channels stretch or shrink a track in real time.
            // The mic starts about a second before the clock does.
            if abs(them.durationSeconds - wallClock) > 1.0 {
                failures.append("them.caf is \(them.durationSeconds)s for \(wallClock)s of recording")
            }
            if you.durationSeconds < wallClock - 1.0 || you.durationSeconds > wallClock + 2.5 {
                failures.append("you.caf is \(you.durationSeconds)s for \(wallClock)s of recording")
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
                     systemInputFormat: session?.systemInputFormatDescription,
                     systemFramesWritten: session?.systemFramesWritten,
                     systemFormatMismatches: session?.systemFormatMismatches,
                     systemConversionFailures: session?.systemConversionFailures,
                     wallClockSeconds: wallClock,
                     toneHz: toneHz,
                     toneWindows: toneWindows,
                     transcript: transcript,
                     passed: failures.isEmpty,
                     failures: failures),
              to: reportURL)

        // A passing self-test must not leave a recording of the room behind.
        // A failing one keeps its audio next to the report as evidence.
        if failures.isEmpty {
            AudioStore.shared.delete(meeting: meeting)
        } else {
            let evidence = reportURL.deletingLastPathComponent().appendingPathComponent("evidence")
            try? FileManager.default.copyItem(at: dir, to: evidence)
        }
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
        await run("/usr/bin/say", [text])
    }

    private static func run(_ executable: String, _ arguments: [String]) async {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.terminationHandler = { _ in continuation.resume() }
            do {
                try process.run()
            } catch {
                logger.error("Could not run \(executable): \(error.localizedDescription)")
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
