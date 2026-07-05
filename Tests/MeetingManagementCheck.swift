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
        try Data("audio".utf8).write(to: audio)
        try Data("texto".utf8).write(to: transcript)

        let original = record(folder: originalFolder, transcript: transcript)
        let service = MeetingFileService()
        let renamed = try service.rename(original, to: "  Reunião Ágil  ")
        check(renamed.title == "Reunião Ágil", "trimmed title")
        check(renamed.folderURL.lastPathComponent == "Reunião Ágil", "renamed folder")
        check(FileManager.default.fileExists(atPath: renamed.audioPath), "audio path updated")
        check(FileManager.default.fileExists(atPath: renamed.transcriptPath!), "transcript path updated")

        let freeTitle = "Synca dia 17/06/2026 às 15:07"
        let freeTitleRenamed = try service.rename(renamed, to: freeTitle)
        check(freeTitleRenamed.title == freeTitle, "free title preserved")
        check(
            freeTitleRenamed.folderURL.lastPathComponent == "Synca dia 17-06-2026 às 15-07",
            "folder title sanitized"
        )
        check(FileManager.default.fileExists(atPath: freeTitleRenamed.audioPath), "free title audio updated")
        check(FileManager.default.fileExists(atPath: freeTitleRenamed.transcriptPath!), "free title transcript updated")

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

        let trashDestination = root.appendingPathComponent("Trash", isDirectory: true)
        let recycleService = MeetingFileService { urls, completion in
            completion([urls[0]: trashDestination], nil)
        }
        try await recycleService.moveToTrash(renamedWithoutTranscript)

        let missing = record(folder: root.appendingPathComponent("Ausente"), transcript: nil)
        do {
            try await recycleService.moveToTrash(missing)
            fail("missing folder should fail")
        } catch MeetingFileError.folderMissing {
        }

        print("Meeting management checks passed")
    }

    private static func record(folder: URL, transcript: URL?) -> MeetingRecord {
        MeetingRecord(
            id: UUID(),
            createdAt: Date(),
            title: folder.lastPathComponent,
            folderPath: folder.path,
            audioPath: folder.appendingPathComponent("audio.wav").path,
            transcriptPath: transcript?.path,
            duration: 1,
            status: .ready,
            errorMessage: nil,
            microphoneName: "Teste"
        )
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
