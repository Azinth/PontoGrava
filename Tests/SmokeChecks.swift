import Foundation

@main
enum SmokeChecks {
    static func main() {
        check(TranscriptFormatter.timestamp(0) == "00:00:00", "timestamp zero")
        check(TranscriptFormatter.timestamp(65.9) == "00:01:05", "timestamp minute")
        check(TranscriptFormatter.timestamp(3_661) == "01:01:01", "timestamp hour")

        let text = TranscriptFormatter.format(
            segments: [
                TranscriptSegment(start: 0, text: " Olá "),
                TranscriptSegment(start: 62, text: "segunda fala")
            ],
            createdAt: Date(timeIntervalSince1970: 0),
            audioFilename: "audio.wav",
            detectedLanguage: "pt"
        )
        check(text.contains("Arquivo: audio.wav"), "audio filename")
        check(text.contains("[00:00:00] Olá"), "trimmed first segment")
        check(text.contains("[00:01:02] segunda fala"), "second segment timestamp")

        let date = Date(timeIntervalSince1970: 1_700_000_000)
        check(MeetingNaming.folderName(for: date).hasPrefix("Reuniao_"), "meeting folder")
        check(
            MeetingNaming.folderName(for: date, imported: true).hasPrefix("Importacao_"),
            "import folder"
        )

        let routeID = UUID()
        check(
            MeetingRoute.meetingID(from: MeetingRoute.url(for: routeID)) == routeID,
            "meeting notification route"
        )
        check(
            MeetingRoute.meetingID(from: URL(string: "pontograva://other/\(routeID)")!) == nil,
            "invalid meeting route"
        )

        var timeline = RecordingTimeline()
        let start = Date(timeIntervalSince1970: 100)
        timeline.start(at: start)
        timeline.pause(at: start.addingTimeInterval(10))
        check(timeline.elapsed(at: start.addingTimeInterval(25)) == 10, "paused clock freezes")
        timeline.resume(at: start.addingTimeInterval(25))
        check(timeline.elapsed(at: start.addingTimeInterval(30)) == 15, "paused interval removed")
        timeline.pause(at: start.addingTimeInterval(35))
        timeline.resume(at: start.addingTimeInterval(40))
        check(timeline.elapsed(at: start.addingTimeInterval(45)) == 25, "multiple pauses removed")
        print("Smoke checks passed")
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ name: String) {
        guard condition() else {
            fputs("Smoke check failed: \(name)\n", stderr)
            exit(1)
        }
    }
}
