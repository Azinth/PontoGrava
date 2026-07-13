import Foundation
import Security

enum RecordingMode: String, CaseIterable, Identifiable {
    case mac
    case discord

    var id: String { rawValue }
    var title: String { self == .mac ? "Mac" : "Discord" }
}

struct DiscordGuild: Codable, Hashable, Identifiable {
    let id: String
    let name: String
}

struct DiscordChannel: Codable, Hashable, Identifiable {
    let id: String
    let name: String
}

struct DiscordRecoveryRequest: Identifiable {
    let folder: URL
    var id: String { folder.path }
}

struct DiscordParticipant: Codable, Hashable {
    let userId: String
    let displayName: String
    let trackPath: String
}

struct DiscordCaptureResult: Codable {
    let guildId: String
    let guildName: String
    let channelId: String
    let channelName: String
    let startedAt: Date
    let durationSeconds: TimeInterval
    let participants: [DiscordParticipant]
    let folderPath: String
    let audioPath: String
    let manifestPath: String
}

struct DiscordManifest: Codable {
    let version: Int
    let guildId: String
    let guildName: String
    let channelId: String
    let channelName: String
    let startedAt: Date
    let durationSeconds: TimeInterval
    let participants: [DiscordParticipant]

    static func load(from folder: URL) throws -> DiscordManifest {
        let url = folder.appendingPathComponent(".discord/manifest.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(DiscordManifest.self, from: Data(contentsOf: url))
    }
}

enum DiscordIntegrationError: LocalizedError {
    case missingNode
    case missingHelper
    case invalidResponse
    case keychain(OSStatus)
    case helperStopped
    case helper(String)

    var errorDescription: String? {
        switch self {
        case .missingNode:
            "Node.js não foi encontrado em /opt/homebrew/bin ou /usr/local/bin."
        case .missingHelper:
            "O helper do Discord não foi encontrado dentro do PontoGrava."
        case .invalidResponse:
            "O helper do Discord retornou uma resposta inválida."
        case let .keychain(status):
            "O token não pôde ser salvo no Chaves do macOS (código \(status))."
        case .helperStopped:
            "O helper do Discord foi encerrado inesperadamente."
        case let .helper(message):
            message
        }
    }
}

enum DiscordTokenStore {
    private static let service = "local.gabriel.pontograva.discord"
    private static let account = "bot-token"

    static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ token: String) throws {
        delete()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(token.utf8)
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw DiscordIntegrationError.keychain(status) }
    }

    static func delete() {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ] as CFDictionary)
    }
}

enum DiscordBotEvent {
    case participant(String)
    case audioLevel(Float)
    case stopped(DiscordCaptureResult)
    case failed(String)
    case helperStopped(String?)
}

@MainActor
final class DiscordBotClient {
    var onEvent: ((DiscordBotEvent) -> Void)?

    private var process: Process?
    private var input: FileHandle?
    private var outputBuffer = Data()
    private var errorOutput = ""
    private var pending: [String: CheckedContinuation<[String: Any], Error>] = [:]

    func connect(token: String) async throws -> (applicationId: String, username: String) {
        let value = try await send(command: "connect", values: ["token": token])
        guard let applicationId = value["applicationId"] as? String,
              let username = value["username"] as? String else {
            throw DiscordIntegrationError.invalidResponse
        }
        return (applicationId, username)
    }

    func listGuilds() async throws -> [DiscordGuild] {
        let value = try await send(command: "listGuilds")
        return try decode([DiscordGuild].self, from: value["guilds"])
    }

    func listChannels(guildId: String) async throws -> [DiscordChannel] {
        let value = try await send(command: "listChannels", values: ["guildId": guildId])
        return try decode([DiscordChannel].self, from: value["channels"])
    }

    func start(guildId: String, channelId: String, folder: URL) async throws {
        _ = try await send(command: "start", values: [
            "guildId": guildId,
            "channelId": channelId,
            "folderPath": folder.path
        ])
    }

    func stop() async throws -> DiscordCaptureResult {
        try decode(DiscordCaptureResult.self, from: await send(command: "stop"))
    }

    func recover(folder: URL) async throws -> DiscordCaptureResult {
        try decode(
            DiscordCaptureResult.self,
            from: await send(command: "recover", values: ["folderPath": folder.path])
        )
    }

    func terminate() {
        process?.terminate()
        process = nil
        input = nil
    }

    private func send(
        command: String,
        values: [String: Any] = [:]
    ) async throws -> [String: Any] {
        try startProcessIfNeeded()
        let id = UUID().uuidString
        var object = values
        object["id"] = id
        object["command"] = command
        let data = try JSONSerialization.data(withJSONObject: object)

        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do {
                try input?.write(contentsOf: data + Data([0x0A]))
            } catch {
                pending.removeValue(forKey: id)
                continuation.resume(throwing: error)
            }
        }
    }

    private func startProcessIfNeeded() throws {
        if process?.isRunning == true { return }
        let fileManager = FileManager.default
        let nodeCandidates = ["/opt/homebrew/bin/node", "/usr/local/bin/node"]
        guard let nodePath = nodeCandidates.first(where: fileManager.fileExists(atPath:)) else {
            throw DiscordIntegrationError.missingNode
        }

        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let helperCandidates = [
            Bundle.main.resourceURL?.appendingPathComponent("DiscordBot/index.js"),
            sourceRoot.appendingPathComponent("DiscordBot/index.js")
        ].compactMap { $0 }
        guard let helper = helperCandidates.first(where: { fileManager.fileExists(atPath: $0.path) }) else {
            throw DiscordIntegrationError.missingHelper
        }

        let standardInput = Pipe()
        let standardOutput = Pipe()
        let standardError = Pipe()
        let process = Process()
        errorOutput = ""
        process.executableURL = URL(fileURLWithPath: nodePath)
        process.arguments = [helper.path]
        process.standardInput = standardInput
        process.standardOutput = standardOutput
        process.standardError = standardError
        process.environment = ProcessInfo.processInfo.environment.merging([
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        ]) { _, new in new }

        standardOutput.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in self?.consume(data) }
        }
        standardError.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if !data.isEmpty, let message = String(data: data, encoding: .utf8) {
                NSLog("Discord helper: %@", message.trimmingCharacters(in: .whitespacesAndNewlines))
                Task { @MainActor in self?.captureError(message) }
            }
        }
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.processStopped() }
        }
        try process.run()
        self.process = process
        input = standardInput.fileHandleForWriting
    }

    private func consume(_ data: Data) {
        outputBuffer.append(data)
        while let newline = outputBuffer.firstIndex(of: 0x0A) {
            let line = outputBuffer[..<newline]
            outputBuffer.removeSubrange(...newline)
            guard !line.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else {
                continue
            }
            handle(object)
        }
    }

    private func handle(_ object: [String: Any]) {
        if object["type"] as? String == "response",
           let id = object["id"] as? String,
           let continuation = pending.removeValue(forKey: id) {
            if object["ok"] as? Bool == true {
                continuation.resume(returning: object["result"] as? [String: Any] ?? [:])
            } else {
                continuation.resume(throwing: DiscordIntegrationError.helper(
                    object["message"] as? String ?? "Falha no helper do Discord."
                ))
            }
            return
        }

        guard object["type"] as? String == "event",
              let name = object["event"] as? String,
              let result = object["result"] as? [String: Any] else { return }
        switch name {
        case "participant":
            if let displayName = result["displayName"] as? String {
                onEvent?(.participant(displayName))
            }
        case "audioLevel":
            if let level = result["level"] as? NSNumber {
                onEvent?(.audioLevel(level.floatValue))
            }
        case "recordingStopped":
            if let capture = try? decode(DiscordCaptureResult.self, from: result) {
                onEvent?(.stopped(capture))
            }
        case "recordingFailed":
            onEvent?(.failed(result["message"] as? String ?? "A gravação do Discord falhou."))
        default:
            break
        }
    }

    private func processStopped() {
        process = nil
        input = nil
        let continuations = pending.values
        pending.removeAll()
        let detail = errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        let error: Error = detail.isEmpty
            ? DiscordIntegrationError.helperStopped
            : DiscordIntegrationError.helper(detail)
        continuations.forEach { $0.resume(throwing: error) }
        onEvent?(.helperStopped(detail.isEmpty ? nil : detail))
    }

    private func captureError(_ message: String) {
        errorOutput += message
        if errorOutput.count > 4_000 {
            errorOutput = String(errorOutput.suffix(4_000))
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from value: Any?) throws -> T {
        guard let value else { throw DiscordIntegrationError.invalidResponse }
        let data = try JSONSerialization.data(withJSONObject: value)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }
}
