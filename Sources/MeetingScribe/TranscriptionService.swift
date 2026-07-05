import AVFoundation
import Foundation
import WhisperKit

actor TranscriptionService {
    static let modelName = "large-v3-v20240930_626MB"
    private static let activityThreshold: Float = 0.015
    private static let activityWindowSeconds: TimeInterval = 0.5
    private static let activityMergeGapSeconds: TimeInterval = 1.4
    private static let minimumRecoverySeconds: TimeInterval = 4
    private static let coveredRangeThreshold = 0.75
    private static let recoveryLeadInSeconds: TimeInterval = 0.5
    private static let recoverySplitBeforeSegmentSeconds: TimeInterval = 0.5

    private var whisperKit: WhisperKit?

    func transcribe(
        audioURL: URL,
        language: TranscriptionLanguage,
        createdAt: Date,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> URL {
        progress(0.05, "Carregando o modelo local…")
        let whisper = try await model()
        progress(0.18, "Analisando o áudio…")

        let languageCode = language.whisperCode
        let options = DecodingOptions(
            language: languageCode,
            usePrefillPrompt: languageCode != nil,
            detectLanguage: languageCode == nil,
            skipSpecialTokens: true,
            chunkingStrategy: .vad
        )

        let results = try await whisper.transcribe(
            audioPath: audioURL.path,
            decodeOptions: options
        ) { partial in
            let detail = partial.text.trimmingCharacters(in: .whitespacesAndNewlines)
            progress(0.55, detail.isEmpty ? "Transcrevendo…" : detail)
            return nil
        }

        var timedSegments = makeTimedSegments(from: results)
        let recoveryClipTimestamps = try recoveryClipTimestamps(
            for: audioURL,
            primarySegments: timedSegments
        )
        if !recoveryClipTimestamps.isEmpty {
            progress(0.74, "Revisando trechos com áudio sem texto…")
            let recoveryOptions = DecodingOptions(
                language: languageCode,
                usePrefillPrompt: languageCode != nil,
                detectLanguage: languageCode == nil,
                skipSpecialTokens: true,
                clipTimestamps: recoveryClipTimestamps,
                chunkingStrategy: nil
            )
            let recoveryResults = try await whisper.transcribe(
                audioPath: audioURL.path,
                decodeOptions: recoveryOptions
            ) { partial in
                let detail = partial.text.trimmingCharacters(in: .whitespacesAndNewlines)
                progress(0.82, detail.isEmpty ? "Revisando trechos…" : detail)
                return nil
            }
            let recoveredSegments = makeTimedSegments(from: recoveryResults)
                .filter { !isRedundant($0, comparedTo: timedSegments) }
            timedSegments.append(contentsOf: recoveredSegments)
        }

        let segments = deduplicated(timedSegments)
            .map { TranscriptSegment(start: $0.start, text: $0.text) }
        guard !segments.isEmpty else { throw AppError.transcriptionReturnedNoText }

        progress(0.92, "Salvando a transcrição…")
        let detectedLanguage = results.first?.language
        let text = TranscriptFormatter.format(
            segments: segments,
            createdAt: createdAt,
            audioFilename: audioURL.lastPathComponent,
            detectedLanguage: detectedLanguage
        )
        let transcriptURL = audioURL.deletingLastPathComponent()
            .appendingPathComponent("transcricao.txt")
        try text.write(to: transcriptURL, atomically: true, encoding: .utf8)
        progress(1, "Transcrição concluída")
        return transcriptURL
    }

    private func model() async throws -> WhisperKit {
        if let whisperKit { return whisperKit }
        let configuration = WhisperKitConfig(
            model: Self.modelName,
            verbose: false,
            prewarm: true,
            load: true,
            download: true,
            useBackgroundDownloadSession: false
        )
        let instance = try await WhisperKit(configuration)
        whisperKit = instance
        return instance
    }

    private struct TimedTranscriptSegment {
        let start: TimeInterval
        let end: TimeInterval
        let text: String
    }

    private struct TimeRange {
        let start: TimeInterval
        let end: TimeInterval

        var duration: TimeInterval { max(0, end - start) }
    }

    private func makeTimedSegments(from results: [TranscriptionResult]) -> [TimedTranscriptSegment] {
        results
            .flatMap(\.segments)
            .map {
                TimedTranscriptSegment(
                    start: TimeInterval($0.start),
                    end: max(TimeInterval($0.end), TimeInterval($0.start)),
                    text: $0.text
                )
            }
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.start < $1.start }
    }

    private func recoveryClipTimestamps(
        for audioURL: URL,
        primarySegments: [TimedTranscriptSegment]
    ) throws -> [Float] {
        let activityRanges = try audioActivityRanges(for: audioURL)
        guard !activityRanges.isEmpty else { return [] }

        var recoveryRanges: [TimeRange] = []
        for activityRange in activityRanges {
            let splitRanges = split(
                activityRange,
                beforeSegmentStartsFrom: primarySegments
            )
            for range in splitRanges where range.duration >= Self.minimumRecoverySeconds {
                let coveredFraction = coveredDuration(
                    in: range,
                    by: primarySegments
                ) / range.duration
                guard coveredFraction < Self.coveredRangeThreshold else { continue }

                let hasSegmentStart = primarySegments.contains {
                    $0.start >= range.start && $0.start < range.end
                }
                guard !hasSegmentStart else { continue }

                let overlapsPreviousSegment = primarySegments.contains {
                    $0.start < range.start && $0.end > range.start
                }
                let start = overlapsPreviousSegment
                    ? range.start + Self.recoveryLeadInSeconds
                    : range.start
                let end = range.end
                guard end - start >= Self.minimumRecoverySeconds else { continue }
                recoveryRanges.append(TimeRange(start: start, end: end))
            }
        }

        return recoveryRanges.flatMap { [Float($0.start), Float($0.end)] }
    }

    private func split(
        _ range: TimeRange,
        beforeSegmentStartsFrom segments: [TimedTranscriptSegment]
    ) -> [TimeRange] {
        let splitPoints = segments
            .map(\.start)
            .filter { $0 > range.start && $0 < range.end }
            .sorted()
        guard !splitPoints.isEmpty else { return [range] }

        var ranges: [TimeRange] = []
        var start = range.start
        for splitPoint in splitPoints {
            let end = max(start, splitPoint - Self.recoverySplitBeforeSegmentSeconds)
            if end - start >= Self.minimumRecoverySeconds {
                ranges.append(TimeRange(start: start, end: end))
            }
            start = splitPoint
        }
        if range.end - start >= Self.minimumRecoverySeconds {
            ranges.append(TimeRange(start: start, end: range.end))
        }
        return ranges
    }

    private func coveredDuration(
        in range: TimeRange,
        by segments: [TimedTranscriptSegment]
    ) -> TimeInterval {
        let intersections = segments
            .compactMap { segment -> TimeRange? in
                let start = max(range.start, segment.start)
                let end = min(range.end, segment.end)
                return end > start ? TimeRange(start: start, end: end) : nil
            }
            .sorted { $0.start < $1.start }

        var covered: TimeInterval = 0
        var currentEnd = range.start
        for intersection in intersections {
            let start = max(intersection.start, currentEnd)
            guard intersection.end > start else { continue }
            covered += intersection.end - start
            currentEnd = max(currentEnd, intersection.end)
        }
        return covered
    }

    private func audioActivityRanges(for audioURL: URL) throws -> [TimeRange] {
        let file = try AVAudioFile(forReading: audioURL)
        let format = file.processingFormat
        let sampleRate = format.sampleRate
        guard sampleRate > 0 else { return [] }

        let windowFrames = AVAudioFrameCount(sampleRate * Self.activityWindowSeconds)
        guard windowFrames > 0 else { return [] }

        var activeRanges: [TimeRange] = []
        while file.framePosition < file.length {
            let startFrame = file.framePosition
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: windowFrames) else {
                break
            }
            try file.read(into: buffer, frameCount: windowFrames)
            let frameLength = Int(buffer.frameLength)
            guard frameLength > 0 else { break }

            if rmsLevel(buffer) >= Self.activityThreshold {
                let start = Double(startFrame) / sampleRate
                let end = Double(startFrame + AVAudioFramePosition(frameLength)) / sampleRate
                activeRanges.append(TimeRange(start: start, end: end))
            }
        }

        return mergeActivityRanges(activeRanges)
            .filter { $0.duration >= Self.minimumRecoverySeconds }
    }

    private func rmsLevel(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0 }
        let channelCount = Int(buffer.format.channelCount)
        let frameLength = Int(buffer.frameLength)
        guard channelCount > 0, frameLength > 0 else { return 0 }

        var sum: Double = 0
        for channel in 0..<channelCount {
            let samples = channelData[channel]
            for frame in 0..<frameLength {
                let sample = Double(samples[frame])
                sum += sample * sample
            }
        }
        return Float(sqrt(sum / Double(channelCount * frameLength)))
    }

    private func mergeActivityRanges(_ ranges: [TimeRange]) -> [TimeRange] {
        var merged: [TimeRange] = []
        for range in ranges.sorted(by: { $0.start < $1.start }) {
            guard let last = merged.last else {
                merged.append(range)
                continue
            }
            if range.start - last.end <= Self.activityMergeGapSeconds {
                merged[merged.count - 1] = TimeRange(
                    start: last.start,
                    end: max(last.end, range.end)
                )
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    private func deduplicated(_ segments: [TimedTranscriptSegment]) -> [TimedTranscriptSegment] {
        var kept: [TimedTranscriptSegment] = []
        for segment in segments.sorted(by: { $0.start < $1.start }) {
            guard !isRedundant(segment, comparedTo: kept) else { continue }
            kept.append(segment)
        }
        return kept
    }

    private func isRedundant(
        _ segment: TimedTranscriptSegment,
        comparedTo existingSegments: [TimedTranscriptSegment]
    ) -> Bool {
        let text = normalized(segment.text)
        guard text.count >= 8 else { return false }
        return existingSegments.contains { normalized($0.text).contains(text) }
    }

    private func normalized(_ text: String) -> String {
        let scalars = text.lowercased().unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.contains(scalar) ? String(scalar) : " "
        }
        return scalars
            .joined()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }
}
