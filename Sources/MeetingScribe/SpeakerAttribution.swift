import AVFoundation
import Foundation

struct SpeakerTrack {
    let displayName: String
    let url: URL
}

enum SpeakerAttribution {
    static func assign(
        _ segments: [TranscriptSegment],
        tracks: [SpeakerTrack],
        minimumRMS: Float = 0.015
    ) -> [TranscriptSegment] {
        let readers = tracks.compactMap { try? SpeakerTrackReader(track: $0) }
        guard !readers.isEmpty else { return segments }

        return segments.map { segment in
            let loudest = readers.compactMap { reader -> (String, Float)? in
                guard let level = try? reader.rms(from: segment.start, to: segment.end) else { return nil }
                return (reader.displayName, level)
            }.max { $0.1 < $1.1 }
            let speaker = loudest.flatMap { $0.1 >= minimumRMS ? $0.0 : nil }
            return TranscriptSegment(
                start: segment.start,
                end: segment.end,
                text: segment.text,
                speaker: speaker
            )
        }
    }
}

private final class SpeakerTrackReader {
    let displayName: String
    private let file: AVAudioFile

    init(track: SpeakerTrack) throws {
        displayName = track.displayName
        file = try AVAudioFile(forReading: track.url)
    }

    func rms(from start: TimeInterval, to end: TimeInterval) throws -> Float {
        let sampleRate = file.processingFormat.sampleRate
        guard sampleRate > 0, file.length > 0 else { return 0 }
        let startFrame = min(
            file.length,
            max(0, AVAudioFramePosition((start * sampleRate).rounded(.down)))
        )
        let minimumEnd = start + 0.25
        let endFrame = min(
            file.length,
            max(startFrame, AVAudioFramePosition((max(end, minimumEnd) * sampleRate).rounded(.up)))
        )
        let frameCount = AVAudioFrameCount(endFrame - startFrame)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: file.processingFormat,
                  frameCapacity: frameCount
              ) else { return 0 }

        file.framePosition = startFrame
        try file.read(into: buffer, frameCount: frameCount)
        guard let channels = buffer.floatChannelData else { return 0 }
        let channelCount = Int(buffer.format.channelCount)
        let sampleCount = Int(buffer.frameLength)
        guard channelCount > 0, sampleCount > 0 else { return 0 }

        var sum: Double = 0
        for channel in 0..<channelCount {
            for frame in 0..<sampleCount {
                let sample = Double(channels[channel][frame])
                sum += sample * sample
            }
        }
        return Float(sqrt(sum / Double(channelCount * sampleCount)))
    }
}
