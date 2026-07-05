import Foundation

@MainActor
final class MeetingStore: ObservableObject {
    @Published private(set) var records: [MeetingRecord] = []

    private let historyURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(applicationSupportURL: URL? = nil) {
        let root = applicationSupportURL ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("PontoGrava", isDirectory: true)
        historyURL = root.appendingPathComponent("historico.json")

        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        load()
    }

    func upsert(_ record: MeetingRecord) {
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record
        } else {
            records.append(record)
        }
        records.sort { $0.createdAt > $1.createdAt }
        save()
    }

    func remove(_ record: MeetingRecord) {
        records.removeAll { $0.id == record.id }
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: historyURL),
              let decoded = try? decoder.decode([MeetingRecord].self, from: data) else {
            return
        }
        records = decoded.sorted { $0.createdAt > $1.createdAt }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: historyURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try encoder.encode(records)
            try data.write(to: historyURL, options: .atomic)
        } catch {
            NSLog("Não foi possível salvar o histórico: %@", error.localizedDescription)
        }
    }
}
