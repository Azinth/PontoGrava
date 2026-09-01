import AppKit
import Foundation

enum MeetingFileError: LocalizedError, Equatable {
    case invalidName
    case folderMissing
    case destinationExists
    case recycleFailed

    var errorDescription: String? {
        switch self {
        case .invalidName:
            "Use um nome que não esteja vazio."
        case .folderMissing:
            "A pasta desta reunião não foi encontrada."
        case .destinationExists:
            "Já existe uma pasta com esse nome. Escolha outro nome."
        case .recycleFailed:
            "Os arquivos não puderam ser movidos para a Lixeira."
        }
    }
}

enum MeetingDeletionScope: String, CaseIterable, Identifiable {
    case audio
    case text
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .audio: "Áudio"
        case .text: "Texto"
        case .all: "Áudio e texto"
        }
    }
}

@MainActor
final class MeetingFileService {
    typealias RecycleCompletion = @Sendable ([URL: URL], Error?) -> Void
    typealias Recycler = ([URL], @escaping RecycleCompletion) -> Void

    private let fileManager: FileManager
    private let recycler: Recycler

    init(
        fileManager: FileManager = .default,
        recycler: @escaping Recycler = { urls, completion in
            NSWorkspace.shared.recycle(urls, completionHandler: completion)
        }
    ) {
        self.fileManager = fileManager
        self.recycler = recycler
    }

    static func validatedName(_ rawName: String) throws -> String {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw MeetingFileError.invalidName
        }
        return name
    }

    nonisolated static func diskUsage(at folder: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .totalFileAllocatedSizeKey,
            .fileAllocatedSizeKey,
            .fileSizeKey,
        ]
        guard let files = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { _, _ in true }
        ) else { return 0 }

        var total: Int64 = 0
        for case let file as URL in files {
            guard let values = try? file.resourceValues(forKeys: keys),
                  values.isRegularFile == true else { continue }
            total += Int64(
                values.totalFileAllocatedSize
                    ?? values.fileAllocatedSize
                    ?? values.fileSize
                    ?? 0
            )
        }
        return total
    }

    func rename(_ record: MeetingRecord, to rawName: String) throws -> MeetingRecord {
        let title = try Self.validatedName(rawName)
        let folderName = Self.safeFolderName(for: title)
        let source = record.folderURL.standardizedFileURL
        guard fileManager.fileExists(atPath: source.path) else {
            throw MeetingFileError.folderMissing
        }

        let destination = source.deletingLastPathComponent()
            .appendingPathComponent(folderName, isDirectory: true)
            .standardizedFileURL

        if destination.path != source.path {
            let isCaseOnlyChange = destination.path.caseInsensitiveCompare(source.path) == .orderedSame
            if fileManager.fileExists(atPath: destination.path), !isCaseOnlyChange {
                throw MeetingFileError.destinationExists
            }

            if isCaseOnlyChange {
                try moveForCaseOnlyRename(from: source, to: destination)
            } else {
                try fileManager.moveItem(at: source, to: destination)
            }
        }

        var renamed = record
        renamed.title = title
        renamed.folderPath = destination.path
        renamed.audioPath = relocatedPath(record.audioPath, from: source, to: destination)
        renamed.transcriptPath = record.transcriptPath.map {
            relocatedPath($0, from: source, to: destination)
        }
        renamed.summaryPath = record.summaryPath.map {
            relocatedPath($0, from: source, to: destination)
        }
        return renamed
    }

    private static func safeFolderName(for title: String) -> String {
        let replacementScalars = CharacterSet(charactersIn: "/:\n\r").union(.controlCharacters)
        var name = title.unicodeScalars
            .map { replacementScalars.contains($0) ? "-" : String($0) }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        while name.contains("--") {
            name = name.replacingOccurrences(of: "--", with: "-")
        }

        if name.isEmpty || name == "." || name == ".." {
            return "Reunião"
        }
        return name
    }

    func hasContent(_ scope: MeetingDeletionScope, in record: MeetingRecord) -> Bool {
        switch scope {
        case .audio:
            fileManager.fileExists(atPath: record.audioPath)
                || fileManager.fileExists(atPath: discordFolder(for: record).path)
        case .text:
            hasTranscript(in: record)
                || record.summaryURL.map { fileManager.fileExists(atPath: $0.path) } == true
        case .all:
            fileManager.fileExists(atPath: record.folderPath)
        }
    }

    func hasTranscript(in record: MeetingRecord) -> Bool {
        record.transcriptURL.map { fileManager.fileExists(atPath: $0.path) } == true
    }

    func eligibleRecords(
        from records: [MeetingRecord],
        for scope: MeetingDeletionScope
    ) -> [MeetingRecord] {
        records
            .filter { hasContent(scope, in: $0) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    func moveToTrash(
        _ record: MeetingRecord,
        scope: MeetingDeletionScope
    ) async throws -> MeetingRecord? {
        switch scope {
        case .all:
            let folder = record.folderURL.standardizedFileURL
            guard fileManager.fileExists(atPath: folder.path) else {
                throw MeetingFileError.folderMissing
            }
            try await recycle([folder])
            return nil
        case .audio:
            let urls = [record.audioURL, discordFolder(for: record)].filter {
                fileManager.fileExists(atPath: $0.path)
            }
            if !urls.isEmpty { try await recycle(urls) }
            return record
        case .text:
            let urls = [record.transcriptURL, record.summaryURL]
                .compactMap { $0 }
                .filter { fileManager.fileExists(atPath: $0.path) }
            if !urls.isEmpty { try await recycle(urls) }
            var updated = record
            updated.transcriptPath = nil
            updated.summaryPath = nil
            return updated
        }
    }

    private func discordFolder(for record: MeetingRecord) -> URL {
        record.folderURL.appendingPathComponent(".discord", isDirectory: true)
    }

    private func recycle(_ urls: [URL]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            recycler(urls) { recycledURLs, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if urls.allSatisfy({ source in
                    recycledURLs.keys.contains { $0.standardizedFileURL == source.standardizedFileURL }
                }) {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: MeetingFileError.recycleFailed)
                }
            }
        }
    }

    private func moveForCaseOnlyRename(from source: URL, to destination: URL) throws {
        let temporary = source.deletingLastPathComponent()
            .appendingPathComponent(".pontograva-renomeando-\(UUID().uuidString)", isDirectory: true)
        try fileManager.moveItem(at: source, to: temporary)
        do {
            try fileManager.moveItem(at: temporary, to: destination)
        } catch {
            try? fileManager.moveItem(at: temporary, to: source)
            throw error
        }
    }

    private func relocatedPath(_ path: String, from source: URL, to destination: URL) -> String {
        let sourcePrefix = source.path.hasSuffix("/") ? source.path : source.path + "/"
        guard path.hasPrefix(sourcePrefix) else {
            return destination.appendingPathComponent(URL(fileURLWithPath: path).lastPathComponent).path
        }
        return destination.appendingPathComponent(String(path.dropFirst(sourcePrefix.count))).path
    }
}
