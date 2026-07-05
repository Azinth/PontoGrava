import SwiftUI

@main
struct PontoGravaApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .environmentObject(model)
                .task { await model.initialize() }
                .onOpenURL { model.handleDeepLink($0) }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    Task { await model.refreshNotificationPermission() }
                }
                .sheet(isPresented: $model.showOnboarding) {
                    OnboardingView()
                        .environmentObject(model)
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
        }
        .defaultSize(width: 420, height: 210)
        .windowResizability(.contentSize)

        WindowGroup("Histórico", id: "history") {
            HistoryWindowView()
                .environmentObject(model)
                .frame(minWidth: 920, minHeight: 610)
        }
        .defaultSize(width: 1_020, height: 680)

        MenuBarExtra(
            "PontoGrava",
            systemImage: model.isPaused ? "pause.circle.fill" : (model.isRecording ? "record.circle.fill" : "waveform")
        ) {
            MenuBarView()
                .environmentObject(model)
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
}
