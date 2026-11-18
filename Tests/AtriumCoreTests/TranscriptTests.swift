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

    @Test func phraseRepeatedAcrossWindowsIsKeptOnce() {
        // From a real call: Whisper repeated a phrase where its windows met.
        let merged = TranscriptMerger.merge(
            me: [],
            them: [them(46.5, 48.4, "What's up, buddy? You miss me already?"),
                   them(48.0, 55.4, "You miss me already? All right, let's hear it.")])
        #expect(merged.map(\.text) == ["What's up, buddy? You miss me already?", "All right, let's hear it."])
    }

    @Test func repeatedWordsLaterInTheCallAreKept() {
        let merged = TranscriptMerger.merge(
            me: [me(0, 2, "I said yes, yes"), me(10, 11, "yes, yes")],
            them: [])
        #expect(merged.map(\.text) == ["I said yes, yes", "yes, yes"])
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

    @Test func unsureStockPhrasesAreNoiseButClearThanksIsKept() {
        func words(_ probabilities: [Double]) -> [Word] {
            probabilities.map { Word(text: "w", start: 0, end: 1, probability: $0) }
        }
        // From a real call: "Thank(0.34) you.(1.00)" over a ringtone.
        #expect(SpeechRecognizer.isStockPhrase("Thank you.", words: words([0.34, 1.0])))
        #expect(!SpeechRecognizer.isStockPhrase("Thank you.", words: words([0.92, 0.99])))
        #expect(!SpeechRecognizer.isStockPhrase("No, it's fine.", words: words([0.2, 0.2, 0.2])))
    }

    @Test func soundLabelsAreNotSpeech() {
        #expect(SpeechRecognizer.clean("*phone ringing*") == "")
        #expect(SpeechRecognizer.clean("[Music] (laughs)") == "")
        #expect(SpeechRecognizer.clean("Hello *coughs* there.") == "Hello there.")
    }
}

@Suite struct SpeechRegionTests {
    private let rate = 16_000

    /// `seconds` of a 300 Hz tone at `db` dBFS RMS, over a noise floor.
    private func audio(_ parts: [(seconds: Double, db: Float?)], noiseDB: Float = -60) -> [Float] {
        var generator = SystemRandomNumberGenerator()
        let noise = pow(10, noiseDB / 20) * 1.7
        return parts.flatMap { part -> [Float] in
            let amplitude = part.db.map { pow(10, $0 / 20) * Float(2).squareRoot() } ?? 0
            return (0..<Int(part.seconds * Double(rate))).map { i in
                amplitude * Float(sin(2 * Double.pi * 300 * Double(i) / Double(rate)))
                    + noise * Float.random(in: -1...1, using: &generator)
            }
        }
    }

    private func seconds(_ regions: [Range<Int>]) -> [(Double, Double)] {
        regions.map { (Double($0.lowerBound) / Double(rate), Double($0.upperBound) / Double(rate)) }
    }

    @Test func quietMicrophoneSpeechIsFound() {
        // From a real call: the user's voice at -40 dB over a -60 dB floor.
        let found = seconds(SpeechRegions.find(in: audio([(3, nil), (2, -40), (3, nil)]), sampleRate: rate))
        #expect(found.count == 1)
        #expect(abs(found[0].0 - 2.7) < 0.15 && abs(found[0].1 - 5.4) < 0.15)
    }

    @Test func shortPausesStayInOneStretchAndLongOnesSplit() {
        let joined = SpeechRegions.find(in: audio([(1, nil), (1, -30), (0.4, nil), (1, -30), (1, nil)]), sampleRate: rate)
        #expect(joined.count == 1)
        let split = SpeechRegions.find(in: audio([(1, nil), (1, -30), (2, nil), (1, -30), (1, nil)]), sampleRate: rate)
        #expect(split.count == 2)
    }

    @Test func digitalSilenceAndFaintNoiseAreNotSpeech() {
        #expect(SpeechRegions.find(in: [Float](repeating: 0, count: rate * 5), sampleRate: rate).isEmpty)
        // Over digital silence the floor is the absolute minimum, not +12 dB.
        let faint = audio([(2, nil), (1, -55), (2, nil)], noiseDB: -200)
        #expect(SpeechRegions.find(in: faint, sampleRate: rate).isEmpty)
    }

    @Test func nonstopSpeechIsFoundAndFitsInWhisperWindows() {
        let regions = seconds(SpeechRegions.find(in: audio([(1, nil), (70, -30), (1, nil)]), sampleRate: rate))
        #expect(regions.count == 3)
        #expect(regions.allSatisfy { $0.1 - $0.0 <= SpeechRegions.maximumSeconds + 1 })
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

    @Test func callAudioIsOneSmallMp4OfBothTracks() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("atrium-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let me = folder.appendingPathComponent(SessionFiles.meRaw)
        let them = folder.appendingPathComponent(SessionFiles.themRaw)
        try writeTrack(me, seconds: 2, amplitude: 0.3)
        try writeTrack(them, seconds: 3, amplitude: 0.3)
        let audio = folder.appendingPathComponent(SessionFiles.audio)
        try await AudioExport.mp4(mixing: [me, them], to: audio)
        let duration = try await AVURLAsset(url: audio).load(.duration).seconds
        #expect(abs(duration - 3) < 0.1)
        // 64 kbps for 3 s is 24 KB; the old export ran near 250 kbps.
        let bytes = try #require(try audio.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        #expect(bytes < 40_000, "\(bytes) bytes for 3 s")
        // Both sources are in the mix: a 440 Hz tone where only `them` plays.
        let track = try #require(ToneAnalysis.monoSamples(of: audio))
        let lastSecond = track.samples[Int(2.2 * track.sampleRate)..<Int(2.8 * track.sampleRate)]
        #expect(try #require(ToneAnalysis.analyse(lastSecond, sampleRate: track.sampleRate)).amplitude > 0.1)
    }
}

