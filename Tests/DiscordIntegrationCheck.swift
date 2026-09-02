import Foundation

@main
enum DiscordIntegrationCheck {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pontograva-discord-check-\(UUID().uuidString)", isDirectory: true)
        let hidden = root.appendingPathComponent(".discord", isDirectory: true)
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let json = """
        {
          "version": 2,
          "status": "complete",
          "guildId": "1",
          "guildName": "Servidor",
          "channelId": "2",
          "channelName": "Geral",
          "startedAt": "2026-07-10T12:00:00Z",
          "durationSeconds": 42,
          "participants": [
            {"userId":"3","displayName":"Ana","trackPath":".discord/tracks/3.wav"}
          ],
          "captureDiagnostics": {
            "participants": [
              {
                "userId":"3",
                "displayName":"Ana",
                "automaticRestarts":1,
                "streamErrors":0,
                "emptyClips":1
              }
            ]
          }
        }
        """
        try Data(json.utf8).write(to: hidden.appendingPathComponent("manifest.json"))
        try Data("audio".utf8).write(to: root.appendingPathComponent("audio.wav"))
        let manifest = try DiscordManifest.load(from: root)
        let request = try JSONDecoder().decode(
            DiscordStartRequest.self,
            from: Data(#"{"requestId":"request","guildId":"guild","channelId":"channel"}"#.utf8)
        )
        let publication = try JSONDecoder().decode(
            DiscordPublicationResult.self,
            from: Data(#"{"textChannelId":"text","messageId":"message"}"#.utf8)
        )
        let transcriptURL = root.appendingPathComponent("transcricao.txt")
        let summaryURL = root.appendingPathComponent("resumo.md")
        try Data("Transcrição inicial".utf8).write(to: transcriptURL)
        try Data("Resumo inicial".utf8).write(to: summaryURL)
        let transcriptOnlyFingerprint = try DiscordPublicationFingerprint.make(
            transcriptURL: transcriptURL,
            summaryURL: nil
        )
        let completeFingerprint = try DiscordPublicationFingerprint.make(
            transcriptURL: transcriptURL,
            summaryURL: summaryURL
        )
        try Data("Resumo alterado".utf8).write(to: summaryURL)
        let modifiedFingerprint = try DiscordPublicationFingerprint.make(
            transcriptURL: transcriptURL,
            summaryURL: summaryURL
        )
        guard manifest.channelName == "Geral",
              manifest.participants.first?.displayName == "Ana",
              manifest.captureDiagnostics?.participants.first?.automaticRestarts == 1,
              manifest.captureDiagnostics?.participants.first?.emptyClips == 1,
              DiscordRecoveryRequest.isRecoverable(in: root),
              request == DiscordStartRequest(
                requestId: "request",
                guildId: "guild",
                channelId: "channel"
              ),
              publication == DiscordPublicationResult(
                textChannelId: "text",
                messageId: "message"
              ),
              transcriptOnlyFingerprint != completeFingerprint,
              completeFingerprint != modifiedFingerprint else {
            throw CheckError.failed
        }

        let legacyJSON = """
        {
          "version": 1,
          "status": "complete",
          "guildId": "1",
          "guildName": "Servidor",
          "channelId": "2",
          "channelName": "Geral",
          "startedAt": "2026-07-10T12:00:00Z",
          "durationSeconds": 42,
          "participants": [
            {"userId":"3","displayName":"Ana","trackPath":".discord/tracks/3.wav"}
          ]
        }
        """
        try Data(legacyJSON.utf8).write(to: hidden.appendingPathComponent("manifest.json"))
        guard try DiscordManifest.load(from: root).captureDiagnostics == nil else {
            throw CheckError.failed
        }

        try FileManager.default.removeItem(at: hidden.appendingPathComponent("manifest.json"))
        try FileManager.default.removeItem(at: root.appendingPathComponent("audio.wav"))
        let sessionURL = hidden.appendingPathComponent("session.json")
        try Data(#"{"clips":[]}"#.utf8).write(to: sessionURL)
        guard !DiscordRecoveryRequest.isRecoverable(in: root) else { throw CheckError.failed }

        try Data(#"{"clips":[{"path":"clips/missing.pcm"}]}"#.utf8).write(to: sessionURL)
        guard !DiscordRecoveryRequest.isRecoverable(in: root) else { throw CheckError.failed }

        let clips = hidden.appendingPathComponent("clips", isDirectory: true)
        try FileManager.default.createDirectory(at: clips, withIntermediateDirectories: true)
        try Data().write(to: clips.appendingPathComponent("empty.pcm"))
        try Data(#"{"clips":[{"path":"clips/empty.pcm"}]}"#.utf8).write(to: sessionURL)
        guard !DiscordRecoveryRequest.isRecoverable(in: root) else { throw CheckError.failed }

        try Data([0, 1]).write(to: clips.appendingPathComponent("audio.pcm"))
        try Data(#"{"clips":[{"path":"clips/audio.pcm"}]}"#.utf8).write(to: sessionURL)
        guard DiscordRecoveryRequest.isRecoverable(in: root) else { throw CheckError.failed }

        try Data("invalid".utf8).write(to: sessionURL)
        guard !DiscordRecoveryRequest.isRecoverable(in: root) else { throw CheckError.failed }
        print("Discord integration checks passed")
    }

    private enum CheckError: Error { case failed }
}
