import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text("PontoGrava")
                    .font(.largeTitle.bold())
                Text("Grave o áudio da reunião e o microfone em uso, depois transcreva tudo neste Mac.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            PermissionRow(
                title: "Microfone",
                description: "Necessário para o microfone do fone com fio, Bluetooth, USB ou do Mac.",
                granted: model.deviceManager.microphonePermissionGranted,
                actionTitle: "Autorizar"
            ) {
                Task { await model.requestMicrophonePermission() }
            }

            PermissionRow(
                title: "Áudio do sistema",
                description: "O macOS apresenta esta permissão como gravação de tela e áudio do sistema.",
                granted: model.deviceManager.screenPermissionGranted,
                actionTitle: "Autorizar"
            ) {
                model.requestScreenPermission()
            }

            PermissionRow(
                title: "Notificações",
                description: "Avisa quando a transcrição estiver pronta ou quando ela precisar ser refeita.",
                granted: model.notificationPermissionState == .authorized,
                actionTitle: model.notificationPermissionState == .denied ? "Abrir Ajustes" : "Autorizar"
            ) {
                if model.notificationPermissionState == .denied {
                    model.openNotificationSettings()
                } else {
                    Task { await model.requestNotificationPermission() }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Label("Processamento local", systemImage: "lock.shield")
                    .font(.headline)
                Text("O Whisper roda no Apple Silicon. Somente o download inicial do modelo precisa de internet.")
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Começar") {
                    model.finishOnboarding()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!model.deviceManager.microphonePermissionGranted)
            }
        }
        .padding(34)
        .frame(width: 720)
        .onAppear { model.refreshMicrophones() }
    }
}

private struct PermissionRow: View {
    let title: String
    let description: String
    let granted: Bool
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                .font(.title2)
                .foregroundStyle(granted ? .green : .secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(description)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(granted ? "Autorizado" : actionTitle, action: action)
                .disabled(granted)
        }
        .padding(16)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }
}
