import SwiftUI

extension AppAppearance {
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

struct AppSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        TabView {
            GeneralSettingsPane()
                .tabItem { Label("Geral", systemImage: "gearshape") }

            AISettingsPane()
                .tabItem { Label("Inteligência Artificial", systemImage: "sparkles") }
        }
        .environmentObject(model)
        .environmentObject(settings)
        .frame(width: 560, height: 350)
        .preferredColorScheme(settings.appearance.colorScheme)
    }
}

private struct GeneralSettingsPane: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section("Aparência") {
                Picker("Tema", selection: $settings.appearance) {
                    ForEach(AppAppearance.allCases) { appearance in
                        Text(appearance.title).tag(appearance)
                    }
                }
                .pickerStyle(.segmented)

                Text(
                    settings.appearance == .system
                        ? "O PontoGrava acompanha automaticamente a aparência do macOS."
                        : "A aparência escolhida é aplicada a todas as janelas do PontoGrava."
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                Text("A alteração de aparência é aplicada e salva automaticamente.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Arquivos") {
                LabeledContent("Pasta de destino") {
                    Text(settings.outputFolderURL.lastPathComponent)
                        .lineLimit(1)
                }

                Text(settings.outputFolderURL.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)

                Button("Alterar pasta…") {
                    model.chooseOutputFolder()
                }
                .disabled(model.isBusy)
            }
        }
        .formStyle(.grouped)
        .padding(.top, 12)
    }
}

private struct AISettingsPane: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @State private var transcriptionProvider = AIProvider.local
    @State private var summaryProvider = AIProvider.local
    @State private var loadedProviders = false
    @State private var showingSummaryPromptEditor = false

    private var usesOpenAI: Bool {
        transcriptionProvider == .openAI || summaryProvider == .openAI
    }

    private var hasProviderChanges: Bool {
        transcriptionProvider != settings.transcriptionProvider
            || summaryProvider != settings.summaryProvider
    }

    private var missingOpenAIKey: Bool {
        usesOpenAI && !model.openAIHasToken
    }

    var body: some View {
        Form {
            Section("Provedores") {
                Picker("Transcrição", selection: $transcriptionProvider) {
                    Text("Local — WhisperKit").tag(AIProvider.local)
                    Text("OpenAI — whisper-1").tag(AIProvider.openAI)
                }

                Picker("Resumo", selection: $summaryProvider) {
                    Text("Local — Apple Intelligence").tag(AIProvider.local)
                    Text("OpenAI — \(OpenAIClient.summaryModel)").tag(AIProvider.openAI)
                }

                HStack {
                    Button("Salvar configurações") {
                        settings.transcriptionProvider = transcriptionProvider
                        settings.summaryProvider = summaryProvider
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!hasProviderChanges || missingOpenAIKey)

                    Spacer()

                    Text(providerStatus)
                        .font(.caption)
                        .foregroundStyle(missingOpenAIKey ? Color.orange : Color.secondary)
                }
            }

            Section("Resumo") {
                LabeledContent("Prompt") {
                    Text(settings.activeCustomSummaryPrompt == nil ? "Padrão" : "Personalizado")
                }

                Button("Configurar prompt…") {
                    showingSummaryPromptEditor = true
                }
                .disabled(model.isBusy)
            }

            Section("Chave da OpenAI") {
                SecureField(
                    model.openAIHasToken ? "Chave salva no Chaves do macOS" : "sk-…",
                    text: $model.openAITokenDraft
                )
                .textFieldStyle(.roundedBorder)

                HStack {
                    Button("Salvar chave") { model.saveOpenAIToken() }
                        .disabled(model.openAITokenDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if model.openAIHasToken {
                        Button("Remover", role: .destructive) { model.removeOpenAIToken() }
                    }

                    Spacer()

                    Label(
                        model.openAIHasToken ? "Chave configurada" : "Chave não configurada",
                        systemImage: model.openAIHasToken ? "checkmark.circle.fill" : "exclamationmark.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(model.openAIHasToken ? Color.green : Color.secondary)
                }

                if let message = model.openAISettingsMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if usesOpenAI {
                Section("Privacidade") {
                    Label(
                        "Quando a transcrição usa OpenAI, o áudio é enviado para a API. Quando o resumo usa OpenAI, o texto da transcrição é enviado. O modo Local mantém esses dados no Mac.",
                        systemImage: "network"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding(.top, 12)
        .onAppear {
            guard !loadedProviders else { return }
            transcriptionProvider = settings.transcriptionProvider
            summaryProvider = settings.summaryProvider
            loadedProviders = true
        }
        .sheet(isPresented: $showingSummaryPromptEditor) {
            SummaryPromptSettingsView()
                .environmentObject(model)
        }
    }

    private var providerStatus: String {
        if missingOpenAIKey {
            return "Salve uma chave para usar OpenAI."
        }
        return hasProviderChanges ? "Alterações não salvas." : "Configurações salvas."
    }
}
