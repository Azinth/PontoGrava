import Foundation

@MainActor
final class AppSettings: ObservableObject {
    @Published var outputFolderPath: String {
        didSet { defaults.set(outputFolderPath, forKey: Keys.outputFolderPath) }
    }

    @Published var language: TranscriptionLanguage {
        didSet { defaults.set(language.rawValue, forKey: Keys.language) }
    }

    @Published var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: Keys.hasCompletedOnboarding) }
    }

    @Published var hasSeenNotificationInvitation: Bool {
        didSet { defaults.set(hasSeenNotificationInvitation, forKey: Keys.hasSeenNotificationInvitation) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let defaultOutput = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PontoGrava", isDirectory: true)
            .path
        outputFolderPath = defaults.string(forKey: Keys.outputFolderPath) ?? defaultOutput
        language = TranscriptionLanguage(
            rawValue: defaults.string(forKey: Keys.language) ?? "automatic"
        ) ?? .automatic
        hasCompletedOnboarding = defaults.bool(forKey: Keys.hasCompletedOnboarding)
        hasSeenNotificationInvitation = defaults.bool(forKey: Keys.hasSeenNotificationInvitation)
    }

    var outputFolderURL: URL {
        URL(fileURLWithPath: outputFolderPath, isDirectory: true)
    }

    func ensureOutputFolder() throws {
        try FileManager.default.createDirectory(
            at: outputFolderURL,
            withIntermediateDirectories: true
        )
    }

    private enum Keys {
        static let outputFolderPath = "outputFolderPath"
        static let language = "transcriptionLanguage"
        static let hasCompletedOnboarding = "hasCompletedOnboarding"
        static let hasSeenNotificationInvitation = "hasSeenNotificationInvitation"
    }
}
