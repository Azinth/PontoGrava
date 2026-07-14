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
            "A pasta não pôde ser movida para a Lixeira."
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

    func moveToTrash(_ record: MeetingRecord) async throws {
        let folder = record.folderURL.standardizedFileURL
        guard fileManager.fileExists(atPath: folder.path) else {
            throw MeetingFileError.folderMissing
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            recycler([folder]) { recycledURLs, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if recycledURLs.keys.contains(where: { $0.standardizedFileURL == folder }) {
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
