import Foundation

enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "Sistema"
        case .light: "Claro"
        case .dark: "Escuro"
        }
    }
}

enum AIProvider: String, CaseIterable, Identifiable {
    case local
    case openAI = "openai"

    var id: String { rawValue }
    var title: String { self == .local ? "Local" : "OpenAI" }
}

@MainActor
final class AppSettings: ObservableObject {
    @Published var appearance: AppAppearance {
        didSet { defaults.set(appearance.rawValue, forKey: Keys.appearance) }
    }

    @Published var transcriptionProvider: AIProvider {
        didSet { defaults.set(transcriptionProvider.rawValue, forKey: Keys.transcriptionProvider) }
    }

    @Published var summaryProvider: AIProvider {
        didSet { defaults.set(summaryProvider.rawValue, forKey: Keys.summaryProvider) }
    }

    @Published var outputFolderPath: String {
        didSet { defaults.set(outputFolderPath, forKey: Keys.outputFolderPath) }
    }

    @Published var language: TranscriptionLanguage {
        didSet { defaults.set(language.rawValue, forKey: Keys.language) }
    }

    @Published var recordingMode: RecordingMode {
        didSet { defaults.set(recordingMode.rawValue, forKey: Keys.recordingMode) }
    }

    @Published var discordGuildID: String? {
        didSet { defaults.set(discordGuildID, forKey: Keys.discordGuildID) }
    }

    @Published var discordChannelID: String? {
        didSet { defaults.set(discordChannelID, forKey: Keys.discordChannelID) }
    }

    @Published var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: Keys.hasCompletedOnboarding) }
    }

    @Published var hasSeenNotificationInvitation: Bool {
        didSet { defaults.set(hasSeenNotificationInvitation, forKey: Keys.hasSeenNotificationInvitation) }
    }

    @Published var automaticallyGenerateSummary: Bool {
        didSet { defaults.set(automaticallyGenerateSummary, forKey: Keys.automaticallyGenerateSummary) }
    }

    @Published var usesCustomSummaryPrompt: Bool {
        didSet { defaults.set(usesCustomSummaryPrompt, forKey: Keys.usesCustomSummaryPrompt) }
    }

    @Published var customSummaryPrompt: String {
        didSet { defaults.set(customSummaryPrompt, forKey: Keys.customSummaryPrompt) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let defaultOutput = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PontoGrava", isDirectory: true)
            .path
        appearance = AppAppearance(
            rawValue: defaults.string(forKey: Keys.appearance) ?? "system"
        ) ?? .system
        transcriptionProvider = AIProvider(
            rawValue: defaults.string(forKey: Keys.transcriptionProvider) ?? "local"
        ) ?? .local
        summaryProvider = AIProvider(
            rawValue: defaults.string(forKey: Keys.summaryProvider) ?? "local"
        ) ?? .local
        outputFolderPath = defaults.string(forKey: Keys.outputFolderPath) ?? defaultOutput
        language = TranscriptionLanguage(
            rawValue: defaults.string(forKey: Keys.language) ?? "automatic"
        ) ?? .automatic
        recordingMode = RecordingMode(
            rawValue: defaults.string(forKey: Keys.recordingMode) ?? "mac"
        ) ?? .mac
        discordGuildID = defaults.string(forKey: Keys.discordGuildID)
        discordChannelID = defaults.string(forKey: Keys.discordChannelID)
        hasCompletedOnboarding = defaults.bool(forKey: Keys.hasCompletedOnboarding)
        hasSeenNotificationInvitation = defaults.bool(forKey: Keys.hasSeenNotificationInvitation)
        automaticallyGenerateSummary = defaults.bool(forKey: Keys.automaticallyGenerateSummary)
        usesCustomSummaryPrompt = defaults.bool(forKey: Keys.usesCustomSummaryPrompt)
        customSummaryPrompt = defaults.string(forKey: Keys.customSummaryPrompt) ?? ""
    }

    var outputFolderURL: URL {
        URL(fileURLWithPath: outputFolderPath, isDirectory: true)
    }

    var activeCustomSummaryPrompt: String? {
        guard usesCustomSummaryPrompt else { return nil }
        let value = customSummaryPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    func ensureOutputFolder() throws {
        try FileManager.default.createDirectory(
            at: outputFolderURL,
            withIntermediateDirectories: true
        )
    }

    private enum Keys {
        static let appearance = "appAppearance"
        static let transcriptionProvider = "transcriptionProvider"
        static let summaryProvider = "summaryProvider"
        static let outputFolderPath = "outputFolderPath"
        static let language = "transcriptionLanguage"
        static let recordingMode = "recordingMode"
        static let discordGuildID = "discordGuildID"
        static let discordChannelID = "discordChannelID"
        static let hasCompletedOnboarding = "hasCompletedOnboarding"
        static let hasSeenNotificationInvitation = "hasSeenNotificationInvitation"
        static let automaticallyGenerateSummary = "automaticallyGenerateSummary"
        static let usesCustomSummaryPrompt = "usesCustomSummaryPrompt"
        static let customSummaryPrompt = "customSummaryPrompt"
    }
}
