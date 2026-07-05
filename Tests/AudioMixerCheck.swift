import AVFoundation
import Foundation

@main
enum AudioMixerCheck {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RegistroLocalMixerCheck-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let systemURL = root.appendingPathComponent("system.caf")
        let microphoneURL = root.appendingPathComponent("microphone.caf")
        let outputURL = root.appendingPathComponent("audio.wav")
        let oneSecond = AVAudioFramePosition(StandardAudio.sampleRate)
        let halfSecond = oneSecond / 2

        try writeTone(to: systemURL, frames: oneSecond, frequency: 440, amplitude: 0.2)
        try writeTone(to: microphoneURL, frames: oneSecond, frequency: 220, amplitude: 0.2)

        let duration = try AudioMixer.mix(
            segments: [
                CapturedSegment(tracks: [
                    CapturedTrack(
                        url: systemURL,
                        firstPresentationTime: 10,
                        frameCount: oneSecond,
                        gain: 0.82
                    ),
                    CapturedTrack(
                        url: microphoneURL,
                        firstPresentationTime: 10.5,
                        frameCount: oneSecond,
                        gain: 1
                    )
                ]),
                CapturedSegment(tracks: [
                    CapturedTrack(
                        url: systemURL,
                        firstPresentationTime: 50,
                        frameCount: halfSecond,
                        gain: 0.82
                    )
                ])
            ],
            to: outputURL
        )

        guard abs(duration - 2) < 0.01 else {
            throw CheckError.failed("expected 2 s without the paused gap, received \(duration)")
        }
        let output = try AVAudioFile(forReading: outputURL)
        guard output.fileFormat.sampleRate == StandardAudio.sampleRate,
              output.fileFormat.channelCount == StandardAudio.channels,
              output.length == AVAudioFramePosition(StandardAudio.sampleRate * 2) else {
            throw CheckError.failed("unexpected WAV format or frame count")
        }

        let silence = AVAudioPCMBuffer(
            pcmFormat: StandardAudio.processingFormat,
            frameCapacity: 128
        )!
        silence.frameLength = 128
        for channel in 0..<Int(StandardAudio.channels) {
            silence.floatChannelData![channel].initialize(repeating: 0, count: 128)
        }
        guard AudioMeter.normalizedLevel(from: silence) == 0 else {
            throw CheckError.failed("silence meter should be zero")
        }

        let tone = AVAudioPCMBuffer(
            pcmFormat: StandardAudio.processingFormat,
            frameCapacity: 128
        )!
        tone.frameLength = 128
        for channel in 0..<Int(StandardAudio.channels) {
            tone.floatChannelData![channel].initialize(repeating: 0.5, count: 128)
        }
        guard AudioMeter.normalizedLevel(from: tone) > 0.8,
              AudioMeter.smoothed(previous: 0.2, next: 0.8) > 0.2 else {
            throw CheckError.failed("audio meter did not react to signal")
        }

        let importedURL = root.appendingPathComponent("imported.wav")
        let importedDuration = try await AudioImportService.convertToStandardWAV(
            source: outputURL,
            destination: importedURL
        )
        let imported = try AVAudioFile(forReading: importedURL)
        guard abs(importedDuration - duration) < 0.01,
              imported.fileFormat.sampleRate == StandardAudio.sampleRate,
              imported.fileFormat.channelCount == StandardAudio.channels else {
            throw CheckError.failed(
                "import duration=\(importedDuration), expected=\(duration), " +
                "rate=\(imported.fileFormat.sampleRate), channels=\(imported.fileFormat.channelCount), " +
                "frames=\(imported.length)"
            )
        }
        print("Audio mixer check passed")
    }

    private static func writeTone(
        to url: URL,
        frames: AVAudioFramePosition,
        frequency: Double,
        amplitude: Float
    ) throws {
        let file = try AVAudioFile(
            forWriting: url,
            settings: StandardAudio.temporaryFileSettings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        var position: AVAudioFramePosition = 0
        while position < frames {
            let count = AVAudioFrameCount(
                min(AVAudioFramePosition(StandardAudio.chunkFrames), frames - position)
            )
            let buffer = AVAudioPCMBuffer(
                pcmFormat: StandardAudio.processingFormat,
                frameCapacity: count
            )!
            buffer.frameLength = count
            for channel in 0..<Int(StandardAudio.channels) {
                let samples = buffer.floatChannelData![channel]
                for frame in 0..<Int(count) {
                    let time = Double(position + AVAudioFramePosition(frame)) / StandardAudio.sampleRate
                    samples[frame] = amplitude * Float(sin(2 * .pi * frequency * time))
                }
            }
            try file.write(from: buffer)
            position += AVAudioFramePosition(count)
        }
    }

    private enum CheckError: Error {
        case failed(String)
    }
}
