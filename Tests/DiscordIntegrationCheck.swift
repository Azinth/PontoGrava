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
        try Data(json.utf8).write(to: hidden.appendingPathComponent("manifest.json"))
        let manifest = try DiscordManifest.load(from: root)
        guard manifest.channelName == "Geral",
              manifest.participants.first?.displayName == "Ana" else {
            throw CheckError.failed
        }
        print("Discord integration checks passed")
    }

    private enum CheckError: Error { case failed }
}
