import SwiftUI

private let onboardingAccent = InterfaceStyle.accent

struct OnboardingView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Label("PontoGrava", systemImage: "waveform.and.mic")
                        .font(.largeTitle.weight(.semibold))
                        .foregroundStyle(onboardingAccent)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Prepare sua primeira reunião").font(.title2.weight(.semibold))
                        Text("Grave, transcreva e revise com processamento local por padrão. Autorize os recursos de captura para começar.")
                            .foregroundStyle(.secondary)
                    }
                    PermissionRow(
                        title: "Microfone", description: "Captura sua voz pelo microfone do Mac, Bluetooth, USB ou fone com fio.",
                        granted: model.deviceManager.microphonePermissionGranted, required: true, actionTitle: "Autorizar"
                    ) { Task { await model.requestMicrophonePermission() } }
                    PermissionRow(
                        title: "Áudio do sistema", description: "O macOS apresenta esta permissão como gravação de tela e áudio do sistema.",
                        granted: model.deviceManager.screenPermissionGranted, required: true, actionTitle: "Autorizar"
                    ) { model.requestScreenPermission() }
                    PermissionRow(
                        title: "Notificações", description: "Avisa quando a transcrição estiver pronta ou precisar de atenção.",
                        granted: model.notificationPermissionState == .authorized, required: false,
                        actionTitle: model.notificationPermissionState == .denied ? "Abrir Ajustes" : "Autorizar"
                    ) {
                        if model.notificationPermissionState == .denied { model.openNotificationSettings() }
                        else { Task { await model.requestNotificationPermission() } }
                    }
                    Label("O processamento local mantém os dados no Mac. A OpenAI pode ser configurada depois, nos Ajustes.", systemImage: "lock.shield")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(24)
            }
            Divider()
            HStack(spacing: 16) {
                Text("Autorize o microfone para continuar.").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button("Começar") { model.finishOnboarding() }
                    .buttonStyle(.borderedProminent)
                    .tint(onboardingAccent)
                    .controlSize(.large)
                    .disabled(!model.deviceManager.microphonePermissionGranted)
            }.padding(20)
        }
        .frame(minWidth: 480, idealWidth: 580, maxWidth: 600, minHeight: 460, idealHeight: 520)
        .preferredColorScheme(settings.appearance.colorScheme)
    }
}

private struct PermissionRow: View {
    let title: String
    let description: String
    let granted: Bool
    let required: Bool
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle.dashed")
                .font(.title2)
                .foregroundStyle(granted ? .green : onboardingAccent)
                .frame(width: 28)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                    Text(required ? "NECESSÁRIO" : "OPCIONAL")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(required ? onboardingAccent : .secondary)
                }
                Text(description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            Button(granted ? "Autorizado" : actionTitle, action: action)
                .disabled(granted)
                .frame(minWidth: 94)
        }
        .padding(15)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 13))
        .accessibilityElement(children: .contain)
    }
}
