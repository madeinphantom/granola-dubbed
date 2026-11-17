import AVFoundation
import Foundation
import Testing
@testable import AtriumCore

@Suite struct TranscriptMergeTests {
    private func me(_ start: Double, _ end: Double, _ text: String) -> Utterance {
        Utterance(speaker: .me, start: start, end: end, text: text)
    }
    private func them(_ start: Double, _ end: Double, _ text: String) -> Utterance {
        Utterance(speaker: .them, start: start, end: end, text: text)
    }

    @Test func speakerComesFromTheTrackAndLinesInterleaveByTime() {
        let merged = TranscriptMerger.merge(
            me: [me(0, 1, "one"), me(4, 5, "three")],
            them: [them(2, 3, "two")])
        #expect(merged.map(\.text) == ["one", "two", "three"])
        #expect(merged.map(\.speaker) == [.me, .them, .me])
    }

    @Test func echoOfTheOtherSideIsDropped() {
        let merged = TranscriptMerger.merge(
            me: [me(0.1, 2.9, "the quick brown fox")],
            them: [them(0, 3, "The quick brown fox jumps.")])
        #expect(merged.map(\.speaker) == [.them])
    }

    @Test func shortRepliesInsideTheirWordsAreKept() {
        // "no" is inside "know" and "ok" inside "took"; substring matching
        // used to delete these as echo.
        let merged = TranscriptMerger.merge(
            me: [me(1, 1.4, "No."), me(3, 3.3, "OK")],
            them: [them(0, 5, "I know it took a while, right?")])
        #expect(merged.filter { $0.speaker == .me }.map(\.text) == ["No.", "OK"])
    }

    @Test func talkingOverEachOtherIsKept() {
        let merged = TranscriptMerger.merge(
            me: [me(0, 2, "sorry, go ahead please")],
            them: [them(0.5, 3, "I was going to say")])
        #expect(merged.count == 2)
    }

    @Test func sameWordsAtADifferentTimeAreNotEcho() {
        let merged = TranscriptMerger.merge(
            me: [me(10, 12, "the quick brown fox")],
            them: [them(0, 3, "the quick brown fox")])
        #expect(merged.count == 2)
    }

    @Test func emptyLinesAreRemoved() {
        #expect(TranscriptMerger.merge(me: [me(0, 1, "  ")], them: [them(1, 2, "...")]).isEmpty)
    }
}

@Suite struct TranscriptRenderTests {
    @Test func consecutiveLinesFromOnePersonFormOneParagraph() {
        let transcript = Transcript(
            recordedAt: Date(timeIntervalSince1970: 0), durationSeconds: 3725, model: "test-model",
            warnings: ["The them side could not be transcribed: boom"],
            utterances: [
                Utterance(speaker: .me, start: 1, end: 2, text: "Hi."),
                Utterance(speaker: .me, start: 2, end: 3, text: "Can you hear me?"),
                Utterance(speaker: .them, start: 3661, end: 3662, text: "Yes."),
            ])
        let md = TranscriptRenderer.markdown(transcript, title: "Call")
        #expect(md.contains("# Call"))
        #expect(md.contains("Duration 01:02:05"))
        #expect(md.contains("> **Warning:** The them side could not be transcribed: boom"))
        #expect(md.contains("**Me** [00:00:01]\nHi. Can you hear me?"))
        #expect(md.contains("**Them** [01:01:01]\nYes."))
    }

    @Test func silenceIsStatedNotLeftBlank() {
        let transcript = Transcript(recordedAt: Date(), durationSeconds: 5, model: "m", warnings: [], utterances: [])
        #expect(TranscriptRenderer.markdown(transcript, title: "Call").contains("No speech was detected"))
    }

    @Test func whisperTokensAreStripped() {
        #expect(SpeechRecognizer.clean("<|startoftranscript|><|en|><|0.00|> Hello, this is a test.<|2.68|>")
                == "Hello, this is a test.")
        #expect(SpeechRecognizer.clean("<|endoftext|>") == "")
    }
}

@Suite struct SessionStoreTests {
    private func tempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("atrium-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func folderStateComesFromItsFiles() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let date = Date(timeIntervalSince1970: 1_800_000_000)

        let done = SessionStore.newSessionFolder(at: date, in: root)
        try FileManager.default.createDirectory(at: done, withIntermediateDirectories: true)
        try "x".write(to: done.appendingPathComponent(SessionFiles.transcriptMarkdown), atomically: true, encoding: .utf8)

        let failed = SessionStore.newSessionFolder(at: date, in: root)
        #expect(failed.lastPathComponent.hasSuffix("(2)"), "same-second calls must not collide")
        try FileManager.default.createDirectory(at: failed, withIntermediateDirectories: true)
        try Data().write(to: failed.appendingPathComponent(SessionFiles.meRaw))
        try "model download failed".write(to: failed.appendingPathComponent(SessionFiles.error),
                                          atomically: true, encoding: .utf8)

        let empty = root.appendingPathComponent("not a call")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)

        let sessions = SessionStore.sessions(in: root)
        #expect(sessions.count == 2)
        #expect(sessions.allSatisfy { abs($0.createdAt.timeIntervalSince(date)) < 1 })
        #expect(sessions.contains { $0.folder == done && $0.state == .transcribed })
        #expect(sessions.contains { $0.folder == failed && $0.state == .untranscribed(error: "model download failed") })
    }
}

@Suite struct RecordingFileTests {
    /// Writes a mono 48 kHz CAF of a sine, like the recorder does.
    private func writeTrack(_ url: URL, seconds: Double, amplitude: Float) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(48_000 * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for i in 0..<Int(frames) {
            buffer.floatChannelData![0][i] = amplitude * Float(sin(2 * Double.pi * 440 * Double(i) / 48_000))
        }
        try file.write(from: buffer)
    }

    @Test func silentSpansAreRecognisedAsSilence() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("atrium-\(UUID()).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeTrack(url, seconds: 1, amplitude: 0)
        let file = try AVAudioFile(forReading: url)
        #expect(try #require(SpeechRecognizer.rms(of: file, from: 0.2, to: 0.8)) < SpeechRecognizer.silenceRMS)
    }

    @Test func speechLevelAudioIsNotSilence() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("atrium-\(UUID()).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeTrack(url, seconds: 1, amplitude: 0.05)
        let file = try AVAudioFile(forReading: url)
        #expect(try #require(SpeechRecognizer.rms(of: file, from: 0.2, to: 0.8)) > SpeechRecognizer.silenceRMS)
    }

    @Test func compressedMixKeepsBothTracksAndPlays() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("atrium-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let me = folder.appendingPathComponent(SessionFiles.meRaw)
        let them = folder.appendingPathComponent(SessionFiles.themRaw)
        try writeTrack(me, seconds: 2, amplitude: 0.3)
        try writeTrack(them, seconds: 3, amplitude: 0.3)
        let mix = folder.appendingPathComponent(SessionFiles.mix)
        try await AudioExport.m4a(mixing: [me, them], to: mix)
        let duration = try await AVURLAsset(url: mix).load(.duration).seconds
        #expect(abs(duration - 3) < 0.1)
    }
}

