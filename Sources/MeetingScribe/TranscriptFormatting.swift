import Foundation

struct TranscriptSegment: Equatable {
    let start: TimeInterval
    let text: String
}

enum TranscriptFormatter {
    static func format(
        segments: [TranscriptSegment],
        createdAt: Date,
        audioFilename: String,
        detectedLanguage: String?
    ) -> String {
        var lines = [
            "TRANSCRIÇÃO LOCAL",
            "Data: \(MeetingNaming.titleFormatter.string(from: createdAt))",
            "Arquivo: \(audioFilename)",
            "Idioma: \(detectedLanguage ?? "automático")",
            String(repeating: "-", count: 48),
            ""
        ]

        lines.append(contentsOf: segments.map { segment in
            "[\(timestamp(segment.start))] \(segment.text.trimmingCharacters(in: .whitespacesAndNewlines))"
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
