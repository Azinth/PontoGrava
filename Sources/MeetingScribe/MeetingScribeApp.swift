import SwiftUI

@main
struct PontoGravaApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .environmentObject(model)
                .environmentObject(model.settings)
                .task { await model.initialize() }
                .onOpenURL { model.handleDeepLink($0) }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    Task { await model.refreshNotificationPermission() }
                }
                .sheet(isPresented: $model.showOnboarding) {
                    OnboardingView()
                        .environmentObject(model)
                        .environmentObject(model.settings)
                        .interactiveDismissDisabled()
                }
                .alert("Atenção", isPresented: warningPresented) {
                    Button("OK", role: .cancel) { model.warningMessage = nil }
                } message: {
                    Text(model.warningMessage ?? "")
                }
                .alert("Erro", isPresented: errorPresented) {
                    Button("OK", role: .cancel) { model.errorMessage = nil }
                } message: {
                    Text(model.errorMessage ?? "")
                }
                .alert(
                    "Recuperar gravação do Discord?",
                    isPresented: recoveryPresented,
                    presenting: model.discordRecoveryRequest
                ) { request in
                    Button("Agora não", role: .cancel) { model.dismissDiscordRecovery() }
                    Button("Recuperar e transcrever") {
                        Task { await model.recoverDiscordSession(request) }
                    }
                } message: { request in
                    Text("Foram encontrados arquivos de \(request.folder.lastPathComponent) que ainda não estão no histórico.")
                }
        }
        .defaultSize(width: 1_180, height: 760)
        .windowResizability(.contentMinSize)

        MenuBarExtra(
            "PontoGrava",
            systemImage: model.isPaused ? "pause.circle.fill" : (model.isRecording ? "record.circle.fill" : "waveform")
        ) {
            MenuBarView()
                .environmentObject(model)
                .environmentObject(model.settings)
        }
        .menuBarExtraStyle(.window)

        Settings {
            AppSettingsView()
                .environmentObject(model)
                .environmentObject(model.settings)
        }
    }

    private var warningPresented: Binding<Bool> {
        Binding(
            get: { model.warningMessage != nil },
            set: { if !$0 { model.warningMessage = nil } }
        )
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )
    }

    private var recoveryPresented: Binding<Bool> {
        Binding(
            get: { model.discordRecoveryRequest != nil },
            set: { if !$0 { model.dismissDiscordRecovery() } }
        )
    }
}
