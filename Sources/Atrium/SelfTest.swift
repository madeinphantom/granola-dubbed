import AppKit
import AtriumCore
import AVFoundation
import Foundation

/// End-to-end check of the real pipeline on real hardware, run inside the
/// installed app so it uses Atrium's own permissions.
///
/// `open -a Atrium --args --selftest /path/to/report.json`
///
/// macOS speaks a known phrase and plays a 1 kHz tone through the speakers
/// while Atrium records. The check then requires: both tracks as long as the
/// wall clock, the tone back at 1 kHz and clean (static and wrong-rate audio
/// are as loud as real audio, so loudness proves nothing), the tone where it
/// was played in time (both tracks aligned to the start), and the phrase in
/// the transcript attributed to "Them". The recording is deleted if it passes
/// and kept next to the report if it fails.
@MainActor
enum SelfTest {
    static let phrase = "Atrium self test. The quick brown fox jumps over the lazy dog."
    static let toneHz = 1000.0
    static let toneSeconds = 3.0
    static let minimumToneSNR = 15.0

    static var requestedReportURL: URL? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "--selftest"), index + 1 < args.count else { return nil }
        return URL(fileURLWithPath: args[index + 1])
    }

    struct Report: Codable {
        var version: String
        var passed: Bool
        var failures: [String]
        var wallClockSeconds: Double?
        var stats: RecordingStats?
        var toneWindows: [ToneAnalysis]
        var transcriptMarkdown: String
    }

    static func run(controller: AppController, reportURL: URL) async {
        var failures: [String] = []
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("atrium-selftest-\(UUID().uuidString)")

        guard let folder = await controller.start(in: root, showingErrors: false) else {
            finish(Report(version: version, passed: false,
                          failures: ["Recording did not start. Check Microphone and Screen & System Audio Recording permissions."],
                          toneWindows: [], transcriptMarkdown: ""), reportURL: reportURL, evidence: nil)
            return
        }
        let started = Date()
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        await run("/usr/bin/say", [phrase])
        try? await Task.sleep(nanoseconds: 500_000_000)

        let toneURL = FileManager.default.temporaryDirectory.appendingPathComponent("atrium-selftest-tone.wav")
        var toneOffset: Double?
        do {
            try ToneAnalysis.writeTone(frequency: toneHz, seconds: toneSeconds, amplitude: 0.8, to: toneURL)
            toneOffset = Date().timeIntervalSince(started)
            await run("/usr/bin/afplay", [toneURL.path])
        } catch {
            failures.append("Could not create the test tone: \(error.localizedDescription)")
        }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let wallClock = Date().timeIntervalSince(started)

        controller.stop()
        try? FileManager.default.removeItem(at: toneURL)
        await controller.waitUntilProcessed(folder)

        let stats = controller.lastStats
        if let stats {
            if abs(stats.themSeconds - wallClock) > 1.0 {
                failures.append("them track is \(stats.themSeconds)s for \(wallClock)s of recording")
            }
            if abs(stats.meSeconds - wallClock) > 1.0 {
                failures.append("me track is \(stats.meSeconds)s for \(wallClock)s of recording")
            }
            if stats.systemFormatMismatches > 0 {
                failures.append("\(stats.systemFormatMismatches) system-audio callbacks did not match the tap format")
            }
            if stats.systemConversionFailures > 0 {
                failures.append("\(stats.systemConversionFailures) system-audio buffers failed conversion")
            }
            if stats.droppedSamples > 0 { failures.append("\(stats.droppedSamples) samples dropped") }
        } else {
            failures.append("The recording could not be saved")
        }

        // Analysed in the kept call.mp4, so the file the user gets is what passes.
        var toneWindows: [ToneAnalysis] = []
        let audioURL = folder.appendingPathComponent(SessionFiles.audio)
        if let toneOffset, let track = ToneAnalysis.monoSamples(of: audioURL) {
            let window = Int(track.sampleRate * 0.3)
            for offset in stride(from: toneOffset + 0.6, through: toneOffset + toneSeconds - 0.9, by: 0.4) {
                let start = Int(offset * track.sampleRate)
                guard start >= 0, start + window <= track.samples.count else {
                    failures.append("\(SessionFiles.audio) ends before the test tone")
                    break
                }
                toneWindows.append(ToneAnalysis.analyse(track.samples[start..<(start + window)],
                                                        sampleRate: track.sampleRate)
                                   ?? ToneAnalysis(frequency: 0, snrDB: -999, amplitude: 0))
            }
            if toneWindows.contains(where: { abs($0.frequency - toneHz) > 5 }) {
                failures.append("Test tone came back at the wrong frequency or the wrong time")
            }
            if toneWindows.contains(where: { $0.snrDB < minimumToneSNR }) {
                failures.append("Test tone is not clean (SNR below \(Int(minimumToneSNR)) dB): noise, static, or loud background audio")
            }
        } else if toneOffset != nil {
            failures.append("Could not read \(SessionFiles.audio)")
        }

        let markdown = (try? String(contentsOf: folder.appendingPathComponent(SessionFiles.transcriptMarkdown),
                                    encoding: .utf8)) ?? ""
        if markdown.isEmpty {
            let error = (try? String(contentsOf: folder.appendingPathComponent(SessionFiles.error), encoding: .utf8)) ?? "unknown"
            failures.append("No transcript was written: \(error)")
        } else {
            // Paragraphs are "**Them** [hh:mm:ss]\ntext".
            let heardByThem = markdown.components(separatedBy: "\n\n")
                .filter { $0.hasPrefix("**\(Speaker.them.label)**") }
                .joined(separator: " ").lowercased()
            if !["quick", "fox", "lazy", "dog"].contains(where: heardByThem.contains) {
                failures.append("The spoken phrase is not in the transcript as \"Them\"")
            }
        }
        let files = Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
        let expected: Set = [SessionFiles.audio, SessionFiles.transcriptMarkdown]
        if files != expected {
            failures.append("The call folder holds \(files.sorted()), not just \(expected.sorted())")
        }

        let report = Report(version: version, passed: failures.isEmpty, failures: failures,
                            wallClockSeconds: wallClock, stats: stats, toneWindows: toneWindows,
                            transcriptMarkdown: markdown)
        finish(report, reportURL: reportURL, evidence: failures.isEmpty ? nil : folder)
        try? FileManager.default.removeItem(at: root)
    }

    private static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    private static func finish(_ report: Report, reportURL: URL, evidence: URL?) {
        if let evidence {
            let destination = reportURL.deletingLastPathComponent().appendingPathComponent("evidence")
            try? FileManager.default.removeItem(at: destination)
            try? FileManager.default.copyItem(at: evidence, to: destination)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(report).write(to: reportURL)
        NSApp.terminate(nil)
    }

    private static func run(_ executable: String, _ arguments: [String]) async {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.terminationHandler = { _ in continuation.resume() }
            do { try process.run() } catch { continuation.resume() }
        }
    }
}

