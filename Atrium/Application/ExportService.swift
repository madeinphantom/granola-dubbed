import Foundation
import UniformTypeIdentifiers

final class ExportService {
    
    enum ExportFormat {
        case markdown, json, srt, txt
        
        var fileExtension: String {
            switch self {
            case .markdown: return "md"
            case .json: return "json"
            case .srt: return "srt"
            case .txt: return "txt"
            }
        }
        
        var contentType: UTType {
            switch self {
            case .markdown: return .plainText
            case .json: return .json
            case .srt: return .plainText
            case .txt: return .plainText
            }
        }
    }
    
    func export(meeting: Meeting, transcript: TranscriptDocument?) -> String {
        // Default to markdown if no format specified
        return generateMarkdown(meeting: meeting, transcript: transcript)
    }
    
    func export(meeting: Meeting, transcript: TranscriptDocument?, format: ExportFormat) -> String {
        switch format {
        case .markdown:
            return generateMarkdown(meeting: meeting, transcript: transcript)
        case .json:
            return generateJSON(meeting: meeting, transcript: transcript)
        case .srt:
            return generateSRT(transcript: transcript)
        case .txt:
            return generateTXT(meeting: meeting, transcript: transcript)
        }
    }
    
    private func generateMarkdown(meeting: Meeting, transcript: TranscriptDocument?) -> String {
        var md = "# \(meeting.title)\n\n"
        md += "\(formatDate(meeting.createdAt)) · \(formatDuration(meeting.duration))\n\n"
        
        if !meeting.notesMarkdown.isEmpty {
            md += "## Notes\n\n\(meeting.notesMarkdown)\n\n"
        }
        
        md += "## Transcript\n\n"
        
        if let transcript = transcript {
            for segment in transcript.segments {
                let speakerLabel = meeting.speakers.first(where: { $0.id == segment.speakerId })?.label ?? "Unknown"
                md += "**\(speakerLabel)** [\(formatTimestamp(segment.start))] \(segment.text)\n\n"
            }
        }
        
        return md
    }
    
    private func generateJSON(meeting: Meeting, transcript: TranscriptDocument?) -> String {
        guard let transcript = transcript else { return "{}" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(transcript) {
            return String(data: data, encoding: .utf8) ?? "{}"
        }
        return "{}"
    }
    
    private func generateSRT(transcript: TranscriptDocument?) -> String {
        guard let transcript = transcript else { return "" }
        var srt = ""
        for (i, segment) in transcript.segments.enumerated() {
            srt += "\(i + 1)\n"
            srt += "\(srtTimestamp(segment.start)) --> \(srtTimestamp(segment.end))\n"
            srt += "\(segment.text)\n\n"
        }
        return srt
    }
    
    private func generateTXT(meeting: Meeting, transcript: TranscriptDocument?) -> String {
        var txt = "\(meeting.title)\n"
        txt += "\(formatDate(meeting.createdAt)) · \(formatDuration(meeting.duration))\n"
        txt += String(repeating: "─", count: 40) + "\n\n"
        
        if let transcript = transcript {
            for segment in transcript.segments {
                let speakerLabel = meeting.speakers.first(where: { $0.id == segment.speakerId })?.label ?? "Unknown"
                txt += "[\(formatTimestamp(segment.start))] \(speakerLabel): \(segment.text)\n"
            }
        }
        
        return txt
    }
    
    // Helpers
    
    private func formatDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
    
    private func formatDuration(_ d: TimeInterval) -> String {
        let m = Int(d) / 60
        let s = Int(d) % 60
        return String(format: "%02d:%02d", m, s)
    }
    
    private func formatTimestamp(_ t: TimeInterval) -> String {
        let m = Int(t) / 60
        let s = Int(t) % 60
        return String(format: "%02d:%02d", m, s)
    }
    
    private func srtTimestamp(_ t: TimeInterval) -> String {
        let h = Int(t) / 3600
        let m = (Int(t) % 3600) / 60
        let s = Int(t) % 60
        let ms = Int((t - Double(Int(t))) * 1000)
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
    }
}
