import AVFoundation
import CoreMedia
import Foundation

enum StandardAudio {
    static let sampleRate: Double = 48_000
    static let channels: AVAudioChannelCount = 2
    static let chunkFrames: AVAudioFrameCount = 8_192

    static var processingFormat: AVAudioFormat {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: false
        )!
    }

    static var wavSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: Int(channels),
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
    }

    static var temporaryFileSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: Int(channels),
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
    }
}

struct CapturedTrack {
    let url: URL
    let firstPresentationTime: Double
    let frameCount: AVAudioFramePosition
    let gain: Float
}

struct CapturedSegment {
    let tracks: [CapturedTrack]
}

enum AudioMeter {
    static func normalizedLevel(from buffer: AVAudioPCMBuffer) -> Float {
        guard let channels = buffer.floatChannelData,
              buffer.frameLength > 0 else { return 0 }

        var sum: Double = 0
        let channelCount = Int(buffer.format.channelCount)
        let frameCount = Int(buffer.frameLength)
        for channel in 0..<channelCount {
            for frame in 0..<frameCount {
                let sample = Double(channels[channel][frame])
                sum += sample * sample
            }
        }
        let rms = sqrt(sum / Double(channelCount * frameCount))
        guard rms > 0.000_001 else { return 0 }
        let decibels = 20 * log10(rms)
        return Float(max(0, min(1, (decibels + 60) / 60)))
    }

    static func smoothed(previous: Float, next: Float) -> Float {
        let factor: Float = next > previous ? 0.58 : 0.16
        return previous + ((next - previous) * factor)
    }
}

final class AudioTrackWriter {
    private let url: URL
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private(set) var firstPresentationTime: Double?
    private(set) var framesWritten: AVAudioFramePosition = 0

    init(url: URL) throws {
        self.url = url
        file = try AVAudioFile(
            forWriting: url,
            settings: StandardAudio.temporaryFileSettings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
    }

    @discardableResult
    func append(_ sampleBuffer: CMSampleBuffer) throws -> Float {
        guard CMSampleBufferIsValid(sampleBuffer),
              CMSampleBufferDataIsReady(sampleBuffer),
              let description = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            throw AppError.invalidAudioBuffer
        }

        let inputFormat = AVAudioFormat(cmAudioFormatDescription: description)
        let sampleCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard sampleCount > 0,
              let inputBuffer = AVAudioPCMBuffer(
                pcmFormat: inputFormat,
                frameCapacity: AVAudioFrameCount(sampleCount)
              ) else {
            throw AppError.invalidAudioBuffer
        }

        inputBuffer.frameLength = AVAudioFrameCount(sampleCount)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(sampleCount),
            into: inputBuffer.mutableAudioBufferList
        )
        guard status == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }

        if firstPresentationTime == nil {
            let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            if timestamp.isValid && !timestamp.isIndefinite {
                firstPresentationTime = timestamp.seconds
            } else {
                firstPresentationTime = 0
            }
        }

        let outputBuffer = try convert(inputBuffer, from: inputFormat)
        guard outputBuffer.frameLength > 0, let file else { return 0 }
        try file.write(from: outputBuffer)
        framesWritten += AVAudioFramePosition(outputBuffer.frameLength)
        return AudioMeter.normalizedLevel(from: outputBuffer)
    }

    func finish(gain: Float) -> CapturedTrack? {
        file = nil
        converter = nil
        converterInputFormat = nil

        guard let firstPresentationTime, framesWritten > 0 else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return CapturedTrack(
            url: url,
            firstPresentationTime: firstPresentationTime,
            frameCount: framesWritten,
            gain: gain
        )
    }

    private func convert(
        _ inputBuffer: AVAudioPCMBuffer,
        from inputFormat: AVAudioFormat
    ) throws -> AVAudioPCMBuffer {
        let target = StandardAudio.processingFormat
        if inputFormat == target {
            return inputBuffer
        }

        if converter == nil || converterInputFormat != inputFormat {
            converter = AVAudioConverter(from: inputFormat, to: target)
            converterInputFormat = inputFormat
        }
        guard let converter else { throw AppError.invalidAudioBuffer }

        let ratio = target.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(inputBuffer.frameLength) * ratio)) + 32
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            throw AppError.invalidAudioBuffer
        }

        var suppliedInput = false
        var conversionError: NSError?
        let conversionStatus = converter.convert(to: outputBuffer, error: &conversionError) {
            _, inputStatus in
            if suppliedInput {
                inputStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            inputStatus.pointee = .haveData
            return inputBuffer
        }

        if let conversionError { throw conversionError }
        if conversionStatus == .error { throw AppError.invalidAudioBuffer }
        return outputBuffer
    }
}

enum AudioMixer {
    static func mix(tracks: [CapturedTrack], to destination: URL) throws -> TimeInterval {
        try mix(segments: [CapturedSegment(tracks: tracks)], to: destination)
    }

    static func mix(segments: [CapturedSegment], to destination: URL) throws -> TimeInterval {
        guard segments.contains(where: { !$0.tracks.isEmpty }) else {
            throw AppError.noAudioCaptured
        }

        let outputFile = try AVAudioFile(
            forWriting: destination,
            settings: StandardAudio.wavSettings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )

        var writtenFrames: AVAudioFramePosition = 0
        for segment in segments where !segment.tracks.isEmpty {
            writtenFrames += try write(segment: segment, to: outputFile)
        }
        guard writtenFrames > 0 else { throw AppError.noAudioCaptured }
        return Double(writtenFrames) / StandardAudio.sampleRate
    }

    static func removeTemporaryTracks(_ tracks: [CapturedTrack]) {
        for track in tracks {
            try? FileManager.default.removeItem(at: track.url)
        }
    }

    private struct MixerSource {
        let track: CapturedTrack
        let file: AVAudioFile
        let offset: AVAudioFramePosition
    }

    private static func write(
        segment: CapturedSegment,
        to outputFile: AVAudioFile
    ) throws -> AVAudioFramePosition {
        let earliestTime = segment.tracks.map(\.firstPresentationTime).min() ?? 0
        let sources = try segment.tracks.map { track in
            MixerSource(
                track: track,
                file: try AVAudioFile(forReading: track.url),
                offset: max(
                    0,
                    AVAudioFramePosition(
                        ((track.firstPresentationTime - earliestTime) * StandardAudio.sampleRate).rounded()
                    )
                )
            )
        }
        let totalFrames = sources.map { $0.offset + $0.track.frameCount }.max() ?? 0
        guard totalFrames > 0 else { return 0 }

        var outputPosition: AVAudioFramePosition = 0
        while outputPosition < totalFrames {
            let frameCount = AVAudioFrameCount(
                min(AVAudioFramePosition(StandardAudio.chunkFrames), totalFrames - outputPosition)
            )
            guard let mixed = AVAudioPCMBuffer(
                pcmFormat: StandardAudio.processingFormat,
                frameCapacity: frameCount
            ) else {
                throw AppError.invalidAudioBuffer
            }
            mixed.frameLength = frameCount
            zero(mixed)

            for source in sources {
                try add(
                    source: source,
                    outputPosition: outputPosition,
                    frameCount: frameCount,
                    into: mixed
                )
            }
            limit(mixed)
            try outputFile.write(from: mixed)
            outputPosition += AVAudioFramePosition(frameCount)
        }
        return totalFrames
    }

    private static func add(
        source: MixerSource,
        outputPosition: AVAudioFramePosition,
        frameCount: AVAudioFrameCount,
        into output: AVAudioPCMBuffer
    ) throws {
        let outputEnd = outputPosition + AVAudioFramePosition(frameCount)
        let sourceStart = source.offset
        let sourceEnd = source.offset + source.track.frameCount
        let overlapStart = max(outputPosition, sourceStart)
        let overlapEnd = min(outputEnd, sourceEnd)
        guard overlapStart < overlapEnd else { return }

        let framesToRead = AVAudioFrameCount(overlapEnd - overlapStart)
        let sourceFrame = overlapStart - sourceStart
        let destinationOffset = Int(overlapStart - outputPosition)
        source.file.framePosition = sourceFrame

        guard let input = AVAudioPCMBuffer(
            pcmFormat: source.file.processingFormat,
            frameCapacity: framesToRead
        ) else {
            throw AppError.invalidAudioBuffer
        }
        try source.file.read(into: input, frameCount: framesToRead)

        guard let inputChannels = input.floatChannelData,
              let outputChannels = output.floatChannelData else {
            throw AppError.invalidAudioBuffer
        }
        let channels = min(Int(input.format.channelCount), Int(output.format.channelCount))
        for channel in 0..<channels {
            for frame in 0..<Int(input.frameLength) {
                outputChannels[channel][destinationOffset + frame] +=
                    inputChannels[channel][frame] * source.track.gain
            }
        }
    }

    private static func zero(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else { return }
        for channel in 0..<Int(buffer.format.channelCount) {
            channels[channel].initialize(repeating: 0, count: Int(buffer.frameLength))
        }
    }

    private static func limit(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else { return }
        for channel in 0..<Int(buffer.format.channelCount) {
            for frame in 0..<Int(buffer.frameLength) {
                channels[channel][frame] = max(-1, min(1, channels[channel][frame]))
            }
        }
    }
}
