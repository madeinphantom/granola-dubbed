import Foundation

public enum Speaker: String, Codable, Sendable {
    /// The microphone: the person running Atrium.
    case me
    /// System audio: everyone else on the call.
    case them

    public var label: String { self == .me ? "Me" : "Them" }
}

public struct Word: Codable, Hashable, Sendable {
    public var text: String
    public var start: Double
    public var end: Double
    public var probability: Double
}

public struct Utterance: Codable, Hashable, Sendable {
    public var speaker: Speaker
    public var start: Double
    public var end: Double
    public var text: String
    public var words: [Word]

    public init(speaker: Speaker, start: Double, end: Double, text: String, words: [Word] = []) {
        self.speaker = speaker
        self.start = start
        self.end = end
        self.text = text
        self.words = words
    }
}

public struct Transcript: Codable, Sendable {
    public var version = 1
    public var recordedAt: Date
    public var durationSeconds: Double
    public var model: String
    /// Problems the reader should know about, e.g. one side failed to transcribe.
    public var warnings: [String]
    public var utterances: [Utterance]
}

public enum TranscriptMerger {
    /// Interleaves both sides of the call by time.
    ///
    /// The speaker of every line is known from its track, so nothing is
    /// guessed. The one correction is speaker bleed: if echo cancellation lets
    /// the remote voice into the microphone, the mic track repeats what the
    /// other side said at the same moment. A mic utterance is dropped as bleed
    /// only if it has at least three words and most of them were said by the
    /// other side in an overlapping utterance. Comparing whole words, not
    /// substrings, keeps short replies like "no" or "ok" that happen to be
    /// spelled inside the other person's words.
    public static func merge(me: [Utterance], them: [Utterance]) -> [Utterance] {
        let remote = them.filter { !tokens($0.text).isEmpty }
        let local = me.filter { mic in
            let micTokens = tokens(mic.text)
            guard !micTokens.isEmpty else { return false }
            return !remote.contains { other in
                mic.start < other.end && other.start < mic.end && isBleed(micTokens, of: tokens(other.text))
            }
        }
        return (local + remote).sorted { $0.start < $1.start }
    }

    static func isBleed(_ mic: [String], of remote: [String]) -> Bool {
        guard mic.count >= 3 else { return false }
        var available = Dictionary(remote.map { ($0, 1) }, uniquingKeysWith: +)
        var matched = 0
        for token in mic where (available[token] ?? 0) > 0 {
            available[token]! -= 1
            matched += 1
        }
        return Double(matched) / Double(mic.count) >= 0.6
    }

    static func tokens(_ text: String) -> [String] {
        text.lowercased()
            .split { !($0.isLetter || $0.isNumber || $0 == "'") }
            .map(String.init)
    }
}

public enum TranscriptRenderer {
    public static func markdown(_ transcript: Transcript, title: String) -> String {
        var lines = ["# \(title)", ""]
        var meta = ["Duration \(timestamp(transcript.durationSeconds))"]
        meta.append("Transcribed locally with \(transcript.model)")
        lines.append(meta.joined(separator: " · "))
        lines.append("")
        for warning in transcript.warnings {
            lines.append("> **Warning:** \(warning)")
            lines.append("")
        }
        if transcript.utterances.isEmpty {
            lines.append("_No speech was detected._")
            lines.append("")
        }
        // Consecutive lines from the same person read as one paragraph.
        var index = 0
        let utterances = transcript.utterances
        while index < utterances.count {
            let speaker = utterances[index].speaker
            let start = utterances[index].start
            var texts: [String] = []
            while index < utterances.count, utterances[index].speaker == speaker {
                texts.append(utterances[index].text)
                index += 1
            }
            lines.append("**\(speaker.label)** [\(timestamp(start))]")
            lines.append(texts.joined(separator: " "))
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    public static func timestamp(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%02d:%02d:%02d", total / 3600, total % 3600 / 60, total % 60)
    }
}

