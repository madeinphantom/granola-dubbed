import Foundation
import OSLog
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Names a call after what was said, with Apple's on-device model. Nothing
/// leaves the Mac. Returns nil where the model is unavailable (before macOS
/// 26, or with Apple Intelligence off); the call then keeps its date name.
public enum CallTitler {
    private static let logger = Logger(subsystem: "app.atrium", category: "CallTitler")
    static let instructions = """
        You name recorded calls. Reply with only a title of 2 to 6 words saying what the call \
        was about, like the name of a meeting. No quotes, no date, no trailing punctuation.
        """
    /// The model's context is about 4,000 tokens; the opening of a call says
    /// what it is about.
    static let maximumCharacters = 8_000
    static let maximumTitleLength = 60

    public static func title(for transcript: Transcript) async -> String? {
        let text = transcript.utterances.map { "\($0.speaker.label): \($0.text)" }.joined(separator: "\n")
        guard TranscriptMerger.tokens(text).count >= 5 else { return nil }
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            guard case .available = SystemLanguageModel.default.availability else { return nil }
            do {
                let session = LanguageModelSession(instructions: instructions)
                let response = try await session.respond(to: String(text.prefix(maximumCharacters)),
                                                         options: GenerationOptions(sampling: .greedy))
                return sanitized(response.content)
            } catch {
                logger.error("Naming the call failed: \(error.localizedDescription)")
            }
        }
        #endif
        return nil
    }

    /// A model reply as a folder and file name.
    static func sanitized(_ reply: String) -> String? {
        var title = reply.components(separatedBy: .newlines).first ?? ""
        title = title.replacingOccurrences(of: "[/:\\\\\"“”*?<>|]", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "^(title|name)\\s+", with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".,;!'`-")))
        if title.count > maximumTitleLength {
            let cut = title.prefix(maximumTitleLength)
            title = String(cut[..<(cut.lastIndex(of: " ") ?? cut.endIndex)])
        }
        return title.isEmpty ? nil : title
    }
}
