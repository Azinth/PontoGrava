import AVFoundation
import Foundation

enum AudioImportService {
    static func convertToStandardWAV(source: URL, destination: URL) async throws -> TimeInterval {
        let asset = AVURLAsset(url: source)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw AppError.noAudioCaptured }

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(
            audioTracks: tracks,
            audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: StandardAudio.sampleRate,
                AVNumberOfChannelsKey: Int(StandardAudio.channels),
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: true
            ]
        )
        guard reader.canAdd(output) else { throw AppError.invalidAudioBuffer }
        reader.add(output)

        let temporaryURL = destination
            .deletingLastPathComponent()
            .appendingPathComponent("importacao.caf")
        let writer = try AudioTrackWriter(url: temporaryURL)
        guard reader.startReading() else {
            throw reader.error ?? AppError.invalidAudioBuffer
        }

        while let sampleBuffer = output.copyNextSampleBuffer() {
            try writer.append(sampleBuffer)
        }
        if reader.status == .failed {
            throw reader.error ?? AppError.invalidAudioBuffer
        }
        guard let track = writer.finish(gain: 1.0) else {
            throw AppError.noAudioCaptured
        }
        let duration = try AudioMixer.mix(tracks: [track], to: destination)
        AudioMixer.removeTemporaryTracks([track])
        return duration
    }
}
