import Foundation

enum TranscriptSource: String {
    case local = "Local"
    case discord = "Discord"
}

struct TranscriptSegment: Equatable {
    let start: TimeInterval
    let end: TimeInterval
    let text: String
    let speaker: String?

    init(start: TimeInterval, end: TimeInterval? = nil, text: String, speaker: String? = nil) {
        self.start = start
        self.end = max(start, end ?? start)
        self.text = text
        self.speaker = speaker
    }
}

enum TranscriptFormatter {
    static func format(
        segments: [TranscriptSegment],
        createdAt: Date,
        audioFilename: String,
        source: TranscriptSource,
        detectedLanguage: String?,
        processing: String = "Local"
    ) -> String {
        var lines = [
            "TRANSCRIÇÃO",
            "Data: \(MeetingNaming.titleFormatter.string(from: createdAt))",
            "Arquivo: \(audioFilename)",
            "Fonte: \(source.rawValue)",
            "Processamento: \(processing)",
            "Idioma: \(detectedLanguage ?? "automático")",
            String(repeating: "-", count: 48),
            ""
        ]

        lines.append(contentsOf: segments.map { segment in
            let speaker = segment.speaker.map { "\($0): " } ?? ""
            return "[\(timestamp(segment.start))] \(speaker)\(segment.text.trimmingCharacters(in: .whitespacesAndNewlines))"
        })
        lines.append("")
        return lines.joined(separator: "\n")
    }

    static func timestamp(_ seconds: TimeInterval) -> String {
        let value = max(0, Int(seconds.rounded(.down)))
        let hours = value / 3_600
        let minutes = (value % 3_600) / 60
        let remainingSeconds = value % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, remainingSeconds)
    }
}
