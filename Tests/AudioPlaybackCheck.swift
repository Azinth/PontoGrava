import AVFoundation
import Foundation

@main
@MainActor
enum AudioPlaybackCheck {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PontoGravaPlayer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let audio = root.appendingPathComponent("audio.wav")
        try writeSilence(to: audio)
        let record = MeetingRecord(
            id: UUID(),
            createdAt: Date(),
            title: "Player",
            folderPath: root.path,
            audioPath: audio.path,
            transcriptPath: nil,
            duration: 1,
            status: .ready,
            errorMessage: nil,
            microphoneName: "Teste"
        )

        let controller = AudioPlaybackController()
        controller.load(record)
        check(controller.isAvailable, "audio available")
        check(controller.loadedRecordID == record.id, "record loaded")
        check(controller.duration == 1, "duration loaded")
        controller.togglePlayback()
        check(controller.isPlaying, "play")
        controller.togglePlayback()
        check(!controller.isPlaying, "pause")
        controller.seek(to: 0.5)
        check(abs(controller.currentTime - 0.5) < 0.01, "seek")
        controller.playbackRate = 1.75
        check(abs(controller.playbackRate - 1.75) < 0.001, "playback rate")
        controller.playbackRate = 1.1
        check(abs(controller.playbackRate - 1.75) < 0.001, "invalid playback rate ignored")
        controller.volume = 0.35
        check(abs(controller.volume - 0.35) < 0.001, "volume")
        controller.reset()
        check(!controller.isAvailable && controller.loadedRecordID == nil, "reset")

        let missingRecord = MeetingRecord(
            id: UUID(),
            createdAt: Date(),
            title: "Ausente",
            folderPath: root.path,
            audioPath: root.appendingPathComponent("missing.wav").path,
            transcriptPath: nil,
            duration: 0,
            status: .ready,
            errorMessage: nil,
            microphoneName: "Teste"
        )
        controller.load(missingRecord)
        check(!controller.isAvailable, "missing audio unavailable")
        print("Audio playback checks passed")
    }

    private static func writeSilence(to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let format = file.processingFormat
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
        buffer.frameLength = 48_000
        for channel in 0..<Int(format.channelCount) {
            buffer.floatChannelData![channel].initialize(repeating: 0, count: 48_000)
        }
        try file.write(from: buffer)
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ name: String) {
        guard condition() else {
            fputs("Audio playback check failed: \(name)\n", stderr)
            exit(1)
        }
    }
}
