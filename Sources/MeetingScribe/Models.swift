import Foundation

enum TranscriptionLanguage: String, CaseIterable, Codable, Identifiable {
    case automatic
    case portuguese
    case english

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: "Detectar automaticamente"
        case .portuguese: "Português"
        case .english: "Inglês"
        }
    }

    var whisperCode: String? {
        switch self {
        case .automatic: nil
        case .portuguese: "pt"
        case .english: "en"
        }
    }
}

enum MeetingStatus: String, Codable {
    case ready
    case transcribing
    case failed

    var title: String {
        switch self {
        case .ready: "Concluída"
        case .transcribing: "Transcrevendo"
        case .failed: "Áudio salvo"
        }
    }
}

struct MeetingRecord: Identifiable, Codable, Hashable {
    let id: UUID
    var createdAt: Date
    var title: String
    var folderPath: String
    var audioPath: String
    var transcriptPath: String?
    var duration: TimeInterval
    var status: MeetingStatus
    var errorMessage: String?
    var microphoneName: String

    var folderURL: URL { URL(fileURLWithPath: folderPath) }
    var audioURL: URL { URL(fileURLWithPath: audioPath) }
    var transcriptURL: URL? { transcriptPath.map(URL.init(fileURLWithPath:)) }
}

struct AudioInputDevice: Identifiable, Hashable {
    let id: String
    let name: String
    let isDefault: Bool
}

enum AppPhase: Equatable {
    case idle
    case preparing
    case recording
    case paused
    case finalizing
    case transcribing

    var title: String {
        switch self {
        case .idle: "Pronto"
        case .preparing: "Preparando gravação"
        case .recording: "Gravando"
        case .paused: "Gravação pausada"
        case .finalizing: "Finalizando o WAV"
        case .transcribing: "Transcrevendo localmente"
        }
    }
}

struct RecordingTimeline: Equatable {
    private(set) var startedAt: Date?
    private(set) var pausedAt: Date?
    private(set) var accumulatedPausedDuration: TimeInterval = 0

    var isPaused: Bool { pausedAt != nil }

    mutating func start(at date: Date) {
        startedAt = date
        pausedAt = nil
        accumulatedPausedDuration = 0
    }

    mutating func pause(at date: Date) {
        guard startedAt != nil, pausedAt == nil else { return }
        pausedAt = date
    }

    mutating func resume(at date: Date) {
        guard let pausedAt else { return }
        accumulatedPausedDuration += max(0, date.timeIntervalSince(pausedAt))
        self.pausedAt = nil
    }

    func elapsed(at date: Date) -> TimeInterval {
        guard let startedAt else { return 0 }
        let end = pausedAt ?? date
        return max(0, end.timeIntervalSince(startedAt) - accumulatedPausedDuration)
    }

    mutating func reset() {
        startedAt = nil
        pausedAt = nil
        accumulatedPausedDuration = 0
    }
}

enum AppError: LocalizedError {
    case microphoneUnavailable
    case microphonePermissionDenied
    case microphoneCaptureFailed(String)
    case screenPermissionDenied
    case screenCaptureFailed(String)
    case noDisplayAvailable
    case recordingNotRunning
    case invalidAudioBuffer
    case noAudioCaptured
    case transcriptionReturnedNoText

    var errorDescription: String? {
        switch self {
        case .microphoneUnavailable:
            "O microfone selecionado não está disponível. Escolha outra entrada antes de gravar."
        case .microphonePermissionDenied:
            "O acesso ao microfone foi negado. Libere-o em Ajustes do Sistema > Privacidade e Segurança > Microfone."
        case let .microphoneCaptureFailed(detail):
            "Não foi possível iniciar a captura do microfone selecionado. \(detail)"
        case .screenPermissionDenied:
            "A captura do áudio do sistema não foi autorizada. Libere o app em Privacidade e Segurança > Gravação de Tela e Áudio do Sistema."
        case let .screenCaptureFailed(detail):
            "Não foi possível iniciar a captura do áudio do sistema. \(detail)"
        case .noDisplayAvailable:
            "Nenhuma tela foi encontrada para iniciar a captura do áudio do sistema."
        case .recordingNotRunning:
            "Não há uma gravação ativa."
        case .invalidAudioBuffer:
            "O macOS forneceu um bloco de áudio inválido."
        case .noAudioCaptured:
            "Nenhum áudio foi capturado."
        case .transcriptionReturnedNoText:
            "O modelo terminou sem produzir texto."
        }
    }
}

enum MeetingManagementRequest: Identifiable {
    case rename(MeetingRecord)
    case delete(MeetingRecord)
    case removeOrphan(MeetingRecord)

    var id: String {
        switch self {
        case let .rename(record): "rename-\(record.id)"
        case let .delete(record): "delete-\(record.id)"
        case let .removeOrphan(record): "orphan-\(record.id)"
        }
    }

    var record: MeetingRecord {
        switch self {
        case let .rename(record), let .delete(record), let .removeOrphan(record): record
        }
    }
}

enum MeetingRoute {
    static func url(for meetingID: UUID) -> URL {
        URL(string: "pontograva://meeting/\(meetingID.uuidString)")!
    }

    static func meetingID(from url: URL) -> UUID? {
        guard url.scheme == "pontograva",
              url.host == "meeting",
              let rawID = url.pathComponents.dropFirst().first else { return nil }
        return UUID(uuidString: rawID)
    }
}

enum MeetingNaming {
    static let folderFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter
    }()

    static let titleFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "pt_BR")
        formatter.dateFormat = "dd/MM/yyyy 'às' HH:mm"
        return formatter
    }()

    static func folderName(for date: Date, imported: Bool = false) -> String {
        "\(imported ? "Importacao" : "Reuniao")_\(folderFormatter.string(from: date))"
    }

    static func title(for date: Date, imported: Bool = false) -> String {
        "\(imported ? "Importação" : "Reunião") de \(titleFormatter.string(from: date))"
    }
}
