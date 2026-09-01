import Foundation

@main
@MainActor
enum MeetingManagementCheck {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PontoGravaManagement-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let originalFolder = root.appendingPathComponent("Original", isDirectory: true)
        try FileManager.default.createDirectory(at: originalFolder, withIntermediateDirectories: true)
        let audio = originalFolder.appendingPathComponent("audio.wav")
        let transcript = originalFolder.appendingPathComponent("transcricao.txt")
        let summary = originalFolder.appendingPathComponent("resumo.md")
        try Data("audio".utf8).write(to: audio)
        try Data("texto".utf8).write(to: transcript)
        try Data("resumo".utf8).write(to: summary)

        let original = record(folder: originalFolder, transcript: transcript, summary: summary)
        let service = MeetingFileService()
        let renamed = try service.rename(original, to: "  Reunião Ágil  ")
        check(renamed.title == "Reunião Ágil", "trimmed title")
        check(renamed.folderURL.lastPathComponent == "Reunião Ágil", "renamed folder")
        check(FileManager.default.fileExists(atPath: renamed.audioPath), "audio path updated")
        check(FileManager.default.fileExists(atPath: renamed.transcriptPath!), "transcript path updated")
        check(FileManager.default.fileExists(atPath: renamed.summaryPath!), "summary path updated")

        let freeTitle = "Synca dia 17/06/2026 às 15:07"
        let freeTitleRenamed = try service.rename(renamed, to: freeTitle)
        check(freeTitleRenamed.title == freeTitle, "free title preserved")
        check(
            freeTitleRenamed.folderURL.lastPathComponent == "Synca dia 17-06-2026 às 15-07",
            "folder title sanitized"
        )
        check(FileManager.default.fileExists(atPath: freeTitleRenamed.audioPath), "free title audio updated")
        check(FileManager.default.fileExists(atPath: freeTitleRenamed.transcriptPath!), "free title transcript updated")
        check(FileManager.default.fileExists(atPath: freeTitleRenamed.summaryPath!), "free title summary updated")

        let caseRenamed = try service.rename(freeTitleRenamed, to: "SYNCA DIA 17/06/2026 ÀS 15:07")
        check(caseRenamed.title == "SYNCA DIA 17/06/2026 ÀS 15:07", "case-only title preserved")
        check(caseRenamed.folderURL.lastPathComponent == "SYNCA DIA 17-06-2026 ÀS 15-07", "case-only rename")
        check(FileManager.default.fileExists(atPath: caseRenamed.audioPath), "case-only audio preserved")

        let support = root.appendingPathComponent("Support", isDirectory: true)
        let store = MeetingStore(applicationSupportURL: support)
        store.upsert(caseRenamed)
        let reloadedStore = MeetingStore(applicationSupportURL: support)
        let persisted = reloadedStore.records.first
        check(persisted?.title == caseRenamed.title, "renamed title persisted")
        check(persisted?.folderPath == caseRenamed.folderPath, "renamed folder path persisted")
        check(persisted?.audioPath == caseRenamed.audioPath, "renamed audio path persisted")
        check(persisted?.transcriptPath == caseRenamed.transcriptPath, "renamed transcript path persisted")
        check(persisted?.summaryPath == caseRenamed.summaryPath, "renamed summary path persisted")

        let legacy = LegacyMeetingRecord(from: caseRenamed)
        let legacyData = try JSONEncoder().encode(legacy)
        let migrated = try JSONDecoder().decode(MeetingRecord.self, from: legacyData)
        check(migrated.summaryPath == nil, "legacy history decodes without summary path")

        let collision = root.appendingPathComponent("Existente", isDirectory: true)
        try FileManager.default.createDirectory(at: collision, withIntermediateDirectories: true)
        expect(MeetingFileError.destinationExists, "collision") {
            _ = try service.rename(caseRenamed, to: "Existente")
        }
        let sanitizedCollision = root.appendingPathComponent("Projeto 17-06-2026 às 15-07", isDirectory: true)
        try FileManager.default.createDirectory(at: sanitizedCollision, withIntermediateDirectories: true)
        expect(MeetingFileError.destinationExists, "sanitized collision") {
            _ = try service.rename(caseRenamed, to: "Projeto 17/06/2026 às 15:07")
        }
        for invalid in ["", "   "] {
            expect(MeetingFileError.invalidName, "invalid name \(invalid)") {
                _ = try MeetingFileService.validatedName(invalid)
            }
        }

        let noTranscriptFolder = root.appendingPathComponent("SemTexto", isDirectory: true)
        try FileManager.default.createDirectory(at: noTranscriptFolder, withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: noTranscriptFolder.appendingPathComponent("audio.wav"))
        let noTranscript = record(folder: noTranscriptFolder, transcript: nil)
        let renamedWithoutTranscript = try service.rename(noTranscript, to: "Somente áudio")
        check(renamedWithoutTranscript.transcriptPath == nil, "missing transcript remains nil")

        let usageFolder = root.appendingPathComponent("Tamanho", isDirectory: true)
        let hiddenUsageFolder = usageFolder.appendingPathComponent(".discord", isDirectory: true)
        try FileManager.default.createDirectory(at: hiddenUsageFolder, withIntermediateDirectories: true)
        try Data(repeating: 0xAB, count: 65_536)
            .write(to: usageFolder.appendingPathComponent("audio.wav"))
        try Data(repeating: 0xCD, count: 32_768)
            .write(to: hiddenUsageFolder.appendingPathComponent("clip.pcm"))
        let usageWithRecovery = MeetingFileService.diskUsage(at: usageFolder)
        try FileManager.default.removeItem(at: hiddenUsageFolder)
        let usageWithoutRecovery = MeetingFileService.diskUsage(at: usageFolder)
        check(usageWithRecovery >= 98_304, "disk usage counts meeting files")
        check(usageWithRecovery > usageWithoutRecovery, "disk usage includes hidden recovery")

        let trashDestination = root.appendingPathComponent("Trash", isDirectory: true)
        let recycleService = recyclingService(trash: trashDestination)

        let audioCleanup = try fixture(in: root, name: "LimparAudio", discord: true)
        let audioResult = try await recycleService.moveToTrash(audioCleanup, scope: .audio)
        check(audioResult?.id == audioCleanup.id, "audio cleanup keeps meeting")
        check(!FileManager.default.fileExists(atPath: audioCleanup.audioPath), "audio removed")
        check(!FileManager.default.fileExists(atPath: audioCleanup.folderURL.appendingPathComponent(".discord").path), "hidden recovery removed")
        check(FileManager.default.fileExists(atPath: audioCleanup.transcriptPath!), "audio cleanup keeps transcript")
        check(FileManager.default.fileExists(atPath: audioCleanup.summaryPath!), "audio cleanup keeps summary")

        let textCleanup = try fixture(in: root, name: "LimparTexto", discord: true)
        let textResult = try await recycleService.moveToTrash(textCleanup, scope: .text)
        check(textResult?.transcriptPath == nil, "text cleanup clears transcript path")
        check(textResult?.summaryPath == nil, "text cleanup clears summary path")
        check(FileManager.default.fileExists(atPath: textCleanup.audioPath), "text cleanup keeps audio")
        check(FileManager.default.fileExists(atPath: textCleanup.folderURL.appendingPathComponent(".discord").path), "text cleanup keeps recovery")
        check(!FileManager.default.fileExists(atPath: textCleanup.transcriptPath!), "transcript removed")
        check(!FileManager.default.fileExists(atPath: textCleanup.summaryPath!), "summary removed")

        let fullCleanup = try fixture(in: root, name: "LimparTudo", discord: true)
        let fullResult = try await recycleService.moveToTrash(fullCleanup, scope: .all)
        check(fullResult == nil, "full cleanup removes meeting")
        check(!FileManager.default.fileExists(atPath: fullCleanup.folderPath), "full folder removed")

        let oldest = Date(timeIntervalSince1970: 1)
        let middle = Date(timeIntervalSince1970: 2)
        let newest = Date(timeIntervalSince1970: 3)
        let textOnly = try fixture(
            in: root,
            name: "SomenteTexto",
            createdAt: oldest,
            audio: false,
            discord: false
        )
        let hiddenOnly = try fixture(
            in: root,
            name: "SomenteRecuperacao",
            createdAt: middle,
            audio: false,
            transcript: false,
            summary: false,
            discord: true
        )
        let newestAudio = try fixture(
            in: root,
            name: "AudioNovo",
            createdAt: newest,
            transcript: false,
            summary: false,
            discord: false
        )
        let audioEligible = recycleService.eligibleRecords(
            from: [newestAudio, textOnly, hiddenOnly],
            for: .audio
        )
        check(audioEligible.map(\.id) == [hiddenOnly.id, newestAudio.id], "oldest eligible audio order")
        let textEligible = recycleService.eligibleRecords(
            from: [newestAudio, textOnly, hiddenOnly],
            for: .text
        )
        check(textEligible.map(\.id) == [textOnly.id], "missing text excluded")

        let failedRecycle = MeetingFileService { _, completion in completion([:], nil) }
        let failedRecord = try fixture(in: root, name: "FalhaLixeira")
        do {
            _ = try await failedRecycle.moveToTrash(failedRecord, scope: .all)
            fail("unconfirmed recycle should fail")
        } catch MeetingFileError.recycleFailed {
        }

        _ = try await recycleService.moveToTrash(renamedWithoutTranscript, scope: .all)

        let missing = record(folder: root.appendingPathComponent("Ausente"), transcript: nil)
        do {
            _ = try await recycleService.moveToTrash(missing, scope: .all)
            fail("missing folder should fail")
        } catch MeetingFileError.folderMissing {
        }

        print("Meeting management checks passed")
    }

    private static func fixture(
        in root: URL,
        name: String,
        createdAt: Date = Date(),
        audio: Bool = true,
        transcript: Bool = true,
        summary: Bool = true,
        discord: Bool = false
    ) throws -> MeetingRecord {
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let audioURL = folder.appendingPathComponent("audio.wav")
        let transcriptURL = folder.appendingPathComponent("transcricao.txt")
        let summaryURL = folder.appendingPathComponent("resumo.md")
        if audio { try Data("audio".utf8).write(to: audioURL) }
        if transcript { try Data("texto".utf8).write(to: transcriptURL) }
        if summary { try Data("resumo".utf8).write(to: summaryURL) }
        if discord {
            let hidden = folder.appendingPathComponent(".discord", isDirectory: true)
            let clips = hidden.appendingPathComponent("clips", isDirectory: true)
            let tracks = hidden.appendingPathComponent("tracks", isDirectory: true)
            try FileManager.default.createDirectory(at: clips, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: tracks, withIntermediateDirectories: true)
            try Data("pcm".utf8).write(to: clips.appendingPathComponent("clip.pcm"))
            try Data("track".utf8).write(to: tracks.appendingPathComponent("participant.wav"))
            try Data("{}".utf8).write(to: hidden.appendingPathComponent("manifest.json"))
        }
        return record(
            folder: folder,
            transcript: transcript ? transcriptURL : nil,
            summary: summary ? summaryURL : nil,
            createdAt: createdAt
        )
    }

    private static func recyclingService(trash: URL) -> MeetingFileService {
        MeetingFileService { urls, completion in
            do {
                try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
                var recycled: [URL: URL] = [:]
                for source in urls {
                    let destination = trash.appendingPathComponent(
                        "\(UUID().uuidString)-\(source.lastPathComponent)"
                    )
                    try FileManager.default.moveItem(at: source, to: destination)
                    recycled[source] = destination
                }
                completion(recycled, nil)
            } catch {
                completion([:], error)
            }
        }
    }

    private static func record(
        folder: URL,
        transcript: URL?,
        summary: URL? = nil,
        createdAt: Date = Date()
    ) -> MeetingRecord {
        MeetingRecord(
            id: UUID(),
            createdAt: createdAt,
            title: folder.lastPathComponent,
            folderPath: folder.path,
            audioPath: folder.appendingPathComponent("audio.wav").path,
            transcriptPath: transcript?.path,
            summaryPath: summary?.path,
            duration: 1,
            status: .ready,
            errorMessage: nil,
            microphoneName: "Teste"
        )
    }

    private struct LegacyMeetingRecord: Codable {
        let id: UUID
        let createdAt: Date
        let title: String
        let folderPath: String
        let audioPath: String
        let transcriptPath: String?
        let duration: TimeInterval
        let status: MeetingStatus
        let errorMessage: String?
        let microphoneName: String

        init(from record: MeetingRecord) {
            id = record.id
            createdAt = record.createdAt
            title = record.title
            folderPath = record.folderPath
            audioPath = record.audioPath
            transcriptPath = record.transcriptPath
            duration = record.duration
            status = record.status
            errorMessage = record.errorMessage
            microphoneName = record.microphoneName
        }
    }

    private static func expect(
        _ expected: MeetingFileError,
        _ name: String,
        operation: () throws -> Void
    ) {
        do {
            try operation()
            fail("\(name) should fail")
        } catch let error as MeetingFileError {
            check(error == expected, name)
        } catch {
            fail("\(name) returned unexpected error")
        }
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ name: String) {
        if !condition() { fail(name) }
    }

    private static func fail(_ name: String) -> Never {
        fputs("Meeting management check failed: \(name)\n", stderr)
        exit(1)
    }
}
