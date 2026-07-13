import AVFoundation
import Foundation

@main
enum SpeakerAttributionCheck {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pontograva-speakers-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let anaURL = root.appendingPathComponent("ana.wav")
        let betoURL = root.appendingPathComponent("beto.wav")
        try writeTrack(anaURL, intervals: [(0..<1, 0.35), (2..<3, 0.2)])
        try writeTrack(betoURL, intervals: [(1..<2, 0.35), (2..<3, 0.5)])

        let segments = [
            TranscriptSegment(start: 0, end: 1, text: "Ana"),
            TranscriptSegment(start: 1, end: 2, text: "Beto"),
            TranscriptSegment(start: 2, end: 3, text: "Sobreposição"),
            TranscriptSegment(start: 3, end: 4, text: "Silêncio")
        ]
        let attributed = SpeakerAttribution.assign(
            segments,
            tracks: [
                SpeakerTrack(displayName: "Ana", url: anaURL),
                SpeakerTrack(displayName: "Beto", url: betoURL)
            ]
        )

        guard attributed.map(\.speaker) == ["Ana", "Beto", "Beto", nil],
              attributed.map(\.start) == segments.map(\.start),
              attributed.map(\.end) == segments.map(\.end) else {
            throw CheckError.failed
        }
        print("Speaker attribution checks passed")
    }

    private static func writeTrack(
        _ url: URL,
        intervals: [(Range<Double>, Float)]
    ) throws {
        let sampleRate = 16_000.0
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!
        let frameCount = AVAudioFrameCount(sampleRate * 4)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        let samples = buffer.floatChannelData![0]
        samples.initialize(repeating: 0, count: Int(frameCount))
        for frame in 0..<Int(frameCount) {
            let time = Double(frame) / sampleRate
            let amplitude = intervals.first { $0.0.contains(time) }?.1 ?? 0
            samples[frame] = amplitude * sin(Float(time * 2 * .pi * 440))
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    private enum CheckError: Error { case failed }
}
