import SwiftUI

private let onboardingAccent = Color(red: 0.79, green: 0.35, blue: 0.21)

struct OnboardingView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 20) {
                Image(systemName: "waveform.and.mic")
                    .font(.system(size: 42, weight: .medium))
                    .foregroundStyle(onboardingAccent)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 8) {
                    Text("PontoGrava")
                        .font(.system(.largeTitle, design: .serif, weight: .semibold))
                    Text("Grave, transcreva e revise reuniões com processamento local por padrão.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                VStack(alignment: .leading, spacing: 8) {
                    Label("Processamento sob seu controle", systemImage: "lock.shield.fill")
                        .font(.headline)
                    Text("O Whisper roda neste Mac. Se preferir, você poderá configurar a OpenAI depois nos Ajustes.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(16)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
            .padding(30)
            .frame(width: 300)
            .frame(maxHeight: .infinity, alignment: .leading)
            .background(onboardingAccent.opacity(0.08))

            Divider()

            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Prepare o aplicativo")
                        .font(.system(.title, design: .serif, weight: .semibold))
                    Text("Autorize o necessário para capturar a reunião. Você pode revisar essas permissões depois.")
                        .foregroundStyle(.secondary)
                }

                PermissionRow(
                    title: "Microfone",
                    description: "Captura sua voz pelo microfone do Mac, Bluetooth, USB ou fone com fio.",
                    granted: model.deviceManager.microphonePermissionGranted,
                    required: true,
                    actionTitle: "Autorizar"
                ) {
                    Task { await model.requestMicrophonePermission() }
                }

                PermissionRow(
                    title: "Áudio do sistema",
                    description: "O macOS apresenta esta permissão como gravação de tela e áudio do sistema.",
                    granted: model.deviceManager.screenPermissionGranted,
                    required: true,
                    actionTitle: "Autorizar"
                ) {
                    model.requestScreenPermission()
                }

                PermissionRow(
                    title: "Notificações",
                    description: "Avisa quando a transcrição estiver pronta ou precisar ser refeita.",
                    granted: model.notificationPermissionState == .authorized,
                    required: false,
                    actionTitle: model.notificationPermissionState == .denied ? "Abrir Ajustes" : "Autorizar"
                ) {
                    if model.notificationPermissionState == .denied {
                        model.openNotificationSettings()
                    } else {
                        Task { await model.requestNotificationPermission() }
                    }
                }

                Spacer()

                HStack {
                    Text("O microfone é necessário para continuar.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Começar") {
                        model.finishOnboarding()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(onboardingAccent)
                    .controlSize(.large)
                    .disabled(!model.deviceManager.microphonePermissionGranted)
                }
            }
            .padding(30)
        }
        .frame(width: 820, height: 560)
        .preferredColorScheme(settings.appearance.colorScheme)
        .onAppear { model.refreshMicrophones() }
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
                HStack(spacing: 7) {
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
