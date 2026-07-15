import AVFoundation
import Foundation

enum OpenAIError: LocalizedError {
    case missingAPIKey
    case invalidAPIKey
    case rateLimited
    case service(Int, String?)
    case network(String)
    case invalidResponse
    case audioPreparation(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            "Adicione uma chave da OpenAI nos Ajustes do PontoGrava."
        case .invalidAPIKey:
            "A chave da OpenAI foi recusada. Confira a credencial nos Ajustes."
        case .rateLimited:
            "A OpenAI limitou temporariamente as solicitações ou a cota disponível. Tente novamente mais tarde."
        case let .service(status, detail):
            if let detail, !detail.isEmpty {
                "A OpenAI retornou o erro \(status): \(detail)"
            } else {
                "A OpenAI retornou o erro \(status). Tente novamente mais tarde."
            }
        case let .network(detail):
            "Não foi possível acessar a OpenAI. \(detail)"
        case .invalidResponse:
            "A OpenAI retornou uma resposta que o PontoGrava não conseguiu interpretar."
        case let .audioPreparation(detail):
            "Não foi possível preparar o áudio para envio. \(detail)"
        }
    }
}

struct OpenAITranscribedSegment: Equatable {
    let start: TimeInterval
    let end: TimeInterval
    let text: String
}

struct OpenAITranscriptionResult: Equatable {
    let language: String?
    let segments: [OpenAITranscribedSegment]
}

struct OpenAIClient {
    static let summaryModel = "gpt-5.6-luna"
    static let transcriptionModel = "whisper-1"

    let apiKey: String
    var session: URLSession = .shared

    func transcribe(fileURL: URL, language: String?) async throws -> OpenAITranscriptionResult {
        let boundary = "PontoGrava-\(UUID().uuidString)"
        let fileData: Data
        do {
            fileData = try Data(contentsOf: fileURL)
        } catch {
            throw OpenAIError.audioPreparation(error.localizedDescription)
        }

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.transcriptionBody(
            fileData: fileData,
            filename: fileURL.lastPathComponent,
            language: language,
            boundary: boundary
        )
        return try Self.decodeTranscription(try await perform(request))
    }

    func meetingSummary(
        instructions: String,
        prompt: String,
        maximumOutputTokens: Int
    ) async throws -> MeetingSummary {
        let text = try await responseText(
            instructions: instructions,
            prompt: prompt,
            maximumOutputTokens: maximumOutputTokens,
            format: Self.meetingSummaryFormat
        )
        return try Self.decodeMeetingSummary(text)
    }

    static func decodeMeetingSummary(_ text: String) throws -> MeetingSummary {
        guard let data = text.data(using: .utf8),
              let value = try? JSONDecoder().decode(MeetingSummaryResponse.self, from: data) else {
            throw OpenAIError.invalidResponse
        }
        return MeetingSummary(
            completedWork: value.completedWork,
            decisions: value.decisions,
            pendingWork: value.pendingWork
        )
    }

    func text(
        instructions: String,
        prompt: String,
        maximumOutputTokens: Int
    ) async throws -> String {
        try await responseText(
            instructions: instructions,
            prompt: prompt,
            maximumOutputTokens: maximumOutputTokens,
            format: nil
        )
    }

    static func decodeTranscription(_ data: Data) throws -> OpenAITranscriptionResult {
        let value: TranscriptionResponse
        do {
            value = try JSONDecoder().decode(TranscriptionResponse.self, from: data)
        } catch {
            throw OpenAIError.invalidResponse
        }
        let segments = value.segments
            .map {
                OpenAITranscribedSegment(
                    start: max(0, $0.start),
                    end: max($0.start, $0.end),
                    text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
            .filter { !$0.text.isEmpty }
        guard !segments.isEmpty else { throw OpenAIError.invalidResponse }
        return OpenAITranscriptionResult(language: value.language, segments: segments)
    }

    static func decodeResponseText(_ data: Data) throws -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let output = root["output"] as? [[String: Any]] else {
            throw OpenAIError.invalidResponse
        }
        for item in output where item["type"] as? String == "message" {
            guard let content = item["content"] as? [[String: Any]] else { continue }
            for part in content where part["type"] as? String == "output_text" {
                if let text = part["text"] as? String,
                   !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return text.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
        throw OpenAIError.invalidResponse
    }

    static func transcriptionBody(
        fileData: Data,
        filename: String,
        language: String?,
        boundary: String
    ) -> Data {
        var body = Data()
        body.appendFormField("model", value: transcriptionModel, boundary: boundary)
        body.appendFormField("response_format", value: "verbose_json", boundary: boundary)
        body.appendFormField("timestamp_granularities[]", value: "segment", boundary: boundary)
        if let language { body.appendFormField("language", value: language, boundary: boundary) }
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n")
        body.append("Content-Type: audio/wav\r\n\r\n")
        body.append(fileData)
        body.append("\r\n--\(boundary)--\r\n")
        return body
    }

    private func responseText(
        instructions: String,
        prompt: String,
        maximumOutputTokens: Int,
        format: [String: Any]?
    ) async throws -> String {
        var payload: [String: Any] = [
            "model": Self.summaryModel,
            "instructions": instructions,
            "input": prompt,
            "store": false,
            "max_output_tokens": maximumOutputTokens,
            "reasoning": ["effort": "low"]
        ]
        if let format { payload["text"] = ["format": format] }

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        return try Self.decodeResponseText(try await perform(request))
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw OpenAIError.invalidResponse
            }
            guard (200..<300).contains(http.statusCode) else {
                throw Self.responseError(statusCode: http.statusCode, data: data)
            }
            return data
        } catch let error as OpenAIError {
            throw error
        } catch let error as URLError {
            throw OpenAIError.network(error.localizedDescription)
        } catch {
            throw OpenAIError.network(error.localizedDescription)
        }
    }

    private static func errorMessage(from data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = root["error"] as? [String: Any] else { return nil }
        return error["message"] as? String
    }

    static func responseError(statusCode: Int, data: Data) -> OpenAIError {
        switch statusCode {
        case 401: .invalidAPIKey
        case 429: .rateLimited
        default: .service(statusCode, errorMessage(from: data))
        }
    }

    private static let meetingSummaryFormat: [String: Any] = [
        "type": "json_schema",
        "name": "meeting_summary",
        "strict": true,
        "schema": [
            "type": "object",
            "properties": [
                "completedWork": ["type": "array", "items": ["type": "string"]],
                "decisions": ["type": "array", "items": ["type": "string"]],
                "pendingWork": ["type": "array", "items": ["type": "string"]]
            ],
            "required": ["completedWork", "decisions", "pendingWork"],
            "additionalProperties": false
        ]
    ]

    private struct TranscriptionResponse: Decodable {
        let language: String?
        let segments: [Segment]

        struct Segment: Decodable {
            let start: Double
            let end: Double
            let text: String
        }
    }

    private struct MeetingSummaryResponse: Decodable {
        let completedWork: [String]
        let decisions: [String]
        let pendingWork: [String]
    }
}

struct OpenAIAudioChunk: Equatable {
    let url: URL
    let startTime: TimeInterval
}

struct OpenAIAudioRange: Equatable {
    let start: TimeInterval
    let duration: TimeInterval
}

enum OpenAIAudioChunker {
    static let chunkDuration: TimeInterval = 8 * 60
    static let overlapDuration: TimeInterval = 1.5
    static let maximumUploadBytes = 24_000_000
    private static let sampleRate: Double = 16_000
    private static let channels: AVAudioChannelCount = 1
    private static let bufferFrames: AVAudioFrameCount = 8_192

    static func ranges(duration: TimeInterval) -> [OpenAIAudioRange] {
        guard duration > 0 else { return [] }
        var result: [OpenAIAudioRange] = []
        var start: TimeInterval = 0
        while start < duration {
            let end = min(duration, start + chunkDuration)
            result.append(OpenAIAudioRange(start: start, duration: end - start))
            guard end < duration else { break }
            start = max(start, end - overlapDuration)
        }
        return result
    }

    static func makeChunks(audioURL: URL, directory: URL) throws -> [OpenAIAudioChunk] {
        let input: AVAudioFile
        do {
            input = try AVAudioFile(forReading: audioURL)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw OpenAIError.audioPreparation(error.localizedDescription)
        }
        let inputRate = input.processingFormat.sampleRate
        guard inputRate > 0 else { throw OpenAIError.audioPreparation("Taxa de amostragem inválida.") }
        let duration = Double(input.length) / inputRate

        return try ranges(duration: duration).enumerated().map { index, range in
            let url = directory.appendingPathComponent(String(format: "trecho-%03d.wav", index + 1))
            let startFrame = AVAudioFramePosition((range.start * inputRate).rounded())
            let frameCount = min(
                input.length - startFrame,
                AVAudioFramePosition((range.duration * inputRate).rounded())
            )
            try convert(
                input: input,
                startFrame: startFrame,
                frameCount: frameCount,
                destination: url
            )
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= maximumUploadBytes else {
                throw OpenAIError.audioPreparation("Um trecho excedeu o limite seguro de upload.")
            }
            return OpenAIAudioChunk(url: url, startTime: range.start)
        }
    }

    private static func convert(
        input: AVAudioFile,
        startFrame: AVAudioFramePosition,
        frameCount: AVAudioFramePosition,
        destination: URL
    ) throws {
        guard frameCount > 0,
              let target = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: channels,
                interleaved: false
              ),
              let converter = AVAudioConverter(from: input.processingFormat, to: target) else {
            throw OpenAIError.audioPreparation("Formato de áudio incompatível.")
        }
        let output = try AVAudioFile(
            forWriting: destination,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: Int(channels),
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ],
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )

        input.framePosition = startFrame
        var remaining = frameCount
        var readError: Error?
        var finished = false
        while !finished {
            guard let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: bufferFrames) else {
                throw OpenAIError.audioPreparation("Não foi possível reservar o buffer de conversão.")
            }
            var conversionError: NSError?
            let status = converter.convert(to: converted, error: &conversionError) { _, inputStatus in
                guard remaining > 0 else {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                let count = AVAudioFrameCount(
                    min(AVAudioFramePosition(bufferFrames), remaining)
                )
                guard let buffer = AVAudioPCMBuffer(
                    pcmFormat: input.processingFormat,
                    frameCapacity: count
                ) else {
                    inputStatus.pointee = .endOfStream
                    readError = OpenAIError.audioPreparation("Não foi possível reservar o buffer de leitura.")
                    return nil
                }
                do {
                    try input.read(into: buffer, frameCount: count)
                } catch {
                    inputStatus.pointee = .endOfStream
                    readError = error
                    return nil
                }
                guard buffer.frameLength > 0 else {
                    inputStatus.pointee = .endOfStream
                    remaining = 0
                    return nil
                }
                remaining -= AVAudioFramePosition(buffer.frameLength)
                inputStatus.pointee = .haveData
                return buffer
            }
            if let readError { throw readError }
            if let conversionError { throw OpenAIError.audioPreparation(conversionError.localizedDescription) }
            if converted.frameLength > 0 { try output.write(from: converted) }
            switch status {
            case .endOfStream: finished = true
            case .error: throw OpenAIError.audioPreparation("A conversão do áudio falhou.")
            case .haveData, .inputRanDry: break
            @unknown default: finished = true
            }
        }
    }
}

private extension Data {
    mutating func append(_ string: String) {
        append(Data(string.utf8))
    }

    mutating func appendFormField(_ name: String, value: String, boundary: String) {
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        append("\(value)\r\n")
    }
}
