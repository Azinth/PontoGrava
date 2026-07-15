import AVFoundation
import Foundation

@main
enum OpenAIIntegrationCheck {
    static func main() async throws {
        try checkDecoding()
        try await checkRequests()
        checkMultipartAndErrors()
        try checkAudioChunks()
        try checkKeychain()
        print("OpenAI integration checks passed")
    }

    private static func checkDecoding() throws {
        let transcription = try OpenAIClient.decodeTranscription(Data(#"""
        {
          "language":"portuguese",
          "segments":[
            {"start":0.25,"end":1.5,"text":" Olá "},
            {"start":1.5,"end":3.0,"text":"segunda fala"}
          ]
        }
        """#.utf8))
        guard transcription.language == "portuguese",
              transcription.segments == [
                OpenAITranscribedSegment(start: 0.25, end: 1.5, text: "Olá"),
                OpenAITranscribedSegment(start: 1.5, end: 3, text: "segunda fala")
              ] else {
            throw CheckError.failed("unexpected transcription decoding")
        }

        let responseText = try OpenAIClient.decodeResponseText(Data(#"""
        {
          "output":[
            {"type":"reasoning","content":[]},
            {"type":"message","content":[{"type":"output_text","text":"resumo pronto"}]}
          ]
        }
        """#.utf8))
        guard responseText == "resumo pronto" else {
            throw CheckError.failed("unexpected Responses API decoding")
        }

        let summary = try OpenAIClient.decodeMeetingSummary(#"""
        {
          "completedWork":["Ana corrigiu o erro."],
          "decisions":["Publicar hoje."],
          "pendingWork":["Bruno fará o teste."]
        }
        """#)
        guard summary.completedWork == ["Ana corrigiu o erro."],
              summary.decisions == ["Publicar hoje."],
              summary.pendingWork == ["Bruno fará o teste."] else {
            throw CheckError.failed("unexpected structured summary decoding")
        }
    }

    private static func checkRequests() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pontograva-openai-request-check-\(UUID().uuidString)", isDirectory: true)
        let audioURL = root.appendingPathComponent("audio.wav")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            FixtureURLProtocol.handler = nil
            try? FileManager.default.removeItem(at: root)
        }
        try writeTone(to: audioURL, seconds: 0.1)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureURLProtocol.self]
        let client = OpenAIClient(
            apiKey: "test-key",
            session: URLSession(configuration: configuration)
        )

        FixtureURLProtocol.handler = { request in
            let body = try requestBody(request)
            guard request.url?.path == "/v1/audio/transcriptions",
                  request.httpMethod == "POST",
                  request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key",
                  String(decoding: body, as: UTF8.self).contains("name=\"model\"\r\n\r\nwhisper-1") else {
                throw CheckError.failed("unexpected transcription request")
            }
            return fixtureResponse(
                request,
                data: Data(#"{"language":"portuguese","segments":[{"start":0,"end":0.1,"text":"Olá"}]}"#.utf8)
            )
        }
        let transcription = try await client.transcribe(fileURL: audioURL, language: "pt")
        guard transcription.language == "portuguese",
              transcription.segments == [OpenAITranscribedSegment(start: 0, end: 0.1, text: "Olá")] else {
            throw CheckError.failed("unexpected transcription fixture result")
        }

        FixtureURLProtocol.handler = { request in
            let body = try requestBody(request)
            guard request.url?.path == "/v1/responses",
                  request.httpMethod == "POST",
                  request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key",
                  let payload = try JSONSerialization.jsonObject(with: body) as? [String: Any],
                  payload["model"] as? String == OpenAIClient.summaryModel,
                  payload["store"] as? Bool == false,
                  let text = payload["text"] as? [String: Any],
                  let format = text["format"] as? [String: Any],
                  format["type"] as? String == "json_schema" else {
                throw CheckError.failed("unexpected structured summary request")
            }
            return fixtureResponse(
                request,
                data: Data(#"{"output":[{"type":"message","content":[{"type":"output_text","text":"{\"completedWork\":[\"Feito\"],\"decisions\":[\"Decidido\"],\"pendingWork\":[\"Pendente\"]}"}]}]}"#.utf8)
            )
        }
        let summary = try await client.meetingSummary(
            instructions: "Resuma sem inventar.",
            prompt: "Transcrição local.",
            maximumOutputTokens: 500
        )
        guard summary.completedWork == ["Feito"],
              summary.decisions == ["Decidido"],
              summary.pendingWork == ["Pendente"] else {
            throw CheckError.failed("unexpected structured summary fixture result")
        }

        FixtureURLProtocol.handler = { request in
            let body = try requestBody(request)
            guard let payload = try JSONSerialization.jsonObject(with: body) as? [String: Any],
                  payload["text"] == nil,
                  payload["instructions"] as? String == "Crie Markdown livre.",
                  payload["input"] as? String == "Transcrição local." else {
                throw CheckError.failed("unexpected custom summary request")
            }
            return fixtureResponse(
                request,
                data: Data(##"{"output":[{"type":"message","content":[{"type":"output_text","text":"# Resumo livre"}]}]}"##.utf8)
            )
        }
        let markdown = try await client.text(
            instructions: "Crie Markdown livre.",
            prompt: "Transcrição local.",
            maximumOutputTokens: 500
        )
        guard markdown == "# Resumo livre" else {
            throw CheckError.failed("unexpected custom summary fixture result")
        }

        FixtureURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        do {
            _ = try await client.text(instructions: "Teste", prompt: "Teste", maximumOutputTokens: 10)
            throw CheckError.failed("network failure was not mapped")
        } catch let error as OpenAIError {
            guard case .network = error else {
                throw CheckError.failed("unexpected network error mapping")
            }
        }
    }

    private static func requestBody(_ request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else {
            throw CheckError.failed("request body missing")
        }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8_192)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { throw stream.streamError ?? CheckError.failed("request body stream failed") }
            if count == 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }

    private static func fixtureResponse(
        _ request: URLRequest,
        data: Data,
        statusCode: Int = 200
    ) -> (HTTPURLResponse, Data) {
        (
            HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!,
            data
        )
    }

    private static func checkMultipartAndErrors() {
        let body = OpenAIClient.transcriptionBody(
            fileData: Data("audio".utf8),
            filename: "trecho.wav",
            language: "pt",
            boundary: "boundary"
        )
        let text = String(decoding: body, as: UTF8.self)
        precondition(text.contains("name=\"model\"\r\n\r\nwhisper-1"))
        precondition(text.contains("name=\"timestamp_granularities[]\"\r\n\r\nsegment"))
        precondition(text.contains("name=\"language\"\r\n\r\npt"))
        precondition(text.contains("filename=\"trecho.wav\""))

        guard case .invalidAPIKey = OpenAIClient.responseError(statusCode: 401, data: Data()),
              case .rateLimited = OpenAIClient.responseError(statusCode: 429, data: Data()),
              case let .service(status, detail) = OpenAIClient.responseError(
                statusCode: 500,
                data: Data(#"{"error":{"message":"indisponível"}}"#.utf8)
              ),
              status == 500,
              detail == "indisponível" else {
            preconditionFailure("unexpected HTTP error mapping")
        }
    }

    private static func checkAudioChunks() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pontograva-openai-check-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("audio.wav")
        let output = root.appendingPathComponent("chunks", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try writeTone(to: source, seconds: 2)
        let chunks = try OpenAIAudioChunker.makeChunks(audioURL: source, directory: output)
        guard chunks.count == 1, chunks[0].startTime == 0 else {
            throw CheckError.failed("unexpected chunk count")
        }
        let file = try AVAudioFile(forReading: chunks[0].url)
        let size = try chunks[0].url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard file.fileFormat.sampleRate == 16_000,
              file.fileFormat.channelCount == 1,
              size > 0,
              size < OpenAIAudioChunker.maximumUploadBytes else {
            throw CheckError.failed("unexpected upload WAV format")
        }

        let ranges = OpenAIAudioChunker.ranges(duration: 1_000)
        guard ranges.count == 3,
              ranges[0] == OpenAIAudioRange(start: 0, duration: 480),
              ranges[1] == OpenAIAudioRange(start: 478.5, duration: 480),
              ranges[2] == OpenAIAudioRange(start: 957, duration: 43) else {
            throw CheckError.failed("unexpected chunk overlap")
        }
    }

    private static func checkKeychain() throws {
        let service = "local.gabriel.pontograva.tests.\(UUID().uuidString)"
        let discordStore = KeychainCredentialStore(
            service: service,
            account: "discord-token"
        )
        let openAIStore = KeychainCredentialStore(
            service: service,
            account: "openai-key"
        )
        discordStore.delete()
        openAIStore.delete()
        defer {
            discordStore.delete()
            openAIStore.delete()
        }
        try discordStore.save("discord-secret")
        try openAIStore.save("secret-one")
        guard discordStore.load() == "discord-secret",
              openAIStore.load() == "secret-one" else {
            throw CheckError.failed("keychain insert failed")
        }
        try openAIStore.save("secret-two")
        guard discordStore.load() == "discord-secret",
              openAIStore.load() == "secret-two" else {
            throw CheckError.failed("keychain update failed")
        }
    }

    private static func writeTone(to url: URL, seconds: Double) throws {
        let file = try AVAudioFile(
            forWriting: url,
            settings: StandardAudio.wavSettings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let frames = AVAudioFramePosition(StandardAudio.sampleRate * seconds)
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
                    samples[frame] = 0.2 * Float(sin(2 * .pi * 440 * time))
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

private final class FixtureURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
