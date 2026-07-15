import Foundation

@main
@MainActor
enum SummaryChecks {
    static func main() {
        let portuguese = """
        TRANSCRIÇÃO LOCAL
        Idioma: pt
        [00:00:01] Vamos publicar na sexta-feira.
        """
        let english = """
        LOCAL TRANSCRIPT
        Idioma: en
        [00:00:01] We will publish on Friday.
        """

        check(SummaryLanguage.detect(in: portuguese) == .portugueseBrazil, "Portuguese locale")
        check(SummaryLanguage.detect(in: english) == .englishUS, "English locale")
        check(
            SummaryLanguage.portugueseBrazil.instructions.contains("The person's locale is pt_BR."),
            "Portuguese locale instruction"
        )
        check(
            SummaryLanguage.portugueseBrazil.instructions.contains("MUST respond in Brazilian Portuguese"),
            "Portuguese response instruction"
        )
        check(
            SummaryLanguage.portugueseBrazil.instructions.contains("NEVER invent"),
            "factual instruction"
        )
        check(
            SummaryLanguage.portugueseBrazil.instructions.contains("Do not rewrite completed work in the future tense"),
            "completed work stays in the past"
        )
        check(
            SummaryLanguage.portugueseBrazil.instructions.contains("\"vou\""),
            "future statements classified as pending"
        )
        check(
            SummaryLanguage.portugueseBrazil.instructions.contains("do not credit work to someone merely because their name appears nearby"),
            "participant attribution stays explicit"
        )
        check(
            SummaryLanguage.portugueseBrazil.instructions.contains("NEVER repeat a fact or list item"),
            "summary items are not repeated"
        )
        let customInstructions = SummaryLanguage.portugueseBrazil.customInstructions(
            "Crie uma seção de riscos."
        )
        check(customInstructions.contains("Crie uma seção de riscos."), "custom prompt instruction")
        check(customInstructions.contains("locale is pt_BR"), "custom prompt locale")
        check(customInstructions.contains("NEVER invent"), "custom prompt remains factual")
        check(
            SummaryPrompt.customTranscriptSection("[00:00:01] Teste").contains("[00:00:01] Teste"),
            "custom prompt receives transcript"
        )
        check(
            SummaryFormatter.customMarkdown("  # Meu resumo  ") == "# Meu resumo\n",
            "custom Markdown normalized"
        )
        let markdown = SummaryFormatter.markdown(
            MeetingSummary(
                completedWork: [
                    "Elison e Gabriel: corrigiram o estorno, o upload da guia e os pagamentos em staging.",
                    "Paulo: subiu o front-end e abriu uma PR para o e-commerce."
                ],
                decisions: ["Publicar na sexta-feira."],
                pendingWork: ["Caio: preparar o documento e solicitar uma reunião com o marketing."]
            ),
            language: .portugueseBrazil
        )
        check(markdown.contains("# Resumo da reunião"), "Portuguese summary heading")
        check(markdown.contains("## O que foi feito"), "completed work heading")
        check(markdown.contains("Elison e Gabriel: corrigiram"), "completed work bullet")
        check(markdown.contains("## O que foi definido"), "decisions heading")
        check(markdown.contains("- Publicar na sexta-feira."), "decision bullet")
        check(markdown.contains("## O que está pendente"), "pending work heading")
        check(markdown.contains("Caio: preparar o documento"), "pending work bullet")

        let empty = SummaryFormatter.markdown(
            MeetingSummary(completedWork: [], decisions: [], pendingWork: []),
            language: .portugueseBrazil
        )
        check(empty.contains("- Nenhum trabalho concluído identificado."), "empty completed work")
        check(empty.contains("- Nenhuma decisão explícita identificada."), "empty decisions")
        check(empty.contains("- Nenhuma pendência explícita identificada."), "empty pending work")

        let longTranscript = (0..<12)
            .map { "[00:00:\(String(format: "%02d", $0))] Linha \($0) com conteúdo da reunião." }
            .joined(separator: "\n")
        let chunks = TranscriptChunker.chunks(longTranscript, maxCharacters: 120)
        check(chunks.count > 1, "long transcript split")
        check(chunks.allSatisfy { $0.count <= 120 }, "chunk size respected")
        check(chunks.first?.hasPrefix("[00:00:00]") == true, "timestamp boundary preserved")

        let oversized = TranscriptChunker.chunks(String(repeating: "palavra ", count: 80), maxCharacters: 60)
        check(oversized.allSatisfy { $0.count <= 60 }, "oversized line split")
        check(
            SummaryGenerationPolicy.shouldWrite(summaryExists: true, overwrite: false) == false,
            "automatic generation preserves summary"
        )
        check(
            SummaryGenerationPolicy.shouldWrite(summaryExists: true, overwrite: true),
            "confirmed regeneration overwrites"
        )

        let suite = "PontoGravaSummaryChecks-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        check(settings.appearance == .system, "appearance defaults to system")
        check(settings.transcriptionProvider == .local, "transcription defaults local")
        check(settings.summaryProvider == .local, "summary defaults local")
        check(!settings.automaticallyGenerateSummary, "automatic summary defaults off")
        check(!settings.usesCustomSummaryPrompt, "custom prompt defaults off")
        check(settings.customSummaryPrompt.isEmpty, "custom prompt defaults empty")
        check(settings.activeCustomSummaryPrompt == nil, "custom prompt inactive by default")
        settings.automaticallyGenerateSummary = true
        settings.usesCustomSummaryPrompt = true
        settings.customSummaryPrompt = "Liste riscos e bloqueios."

        settings.appearance = .light
        check(AppSettings(defaults: defaults).appearance == .light, "light appearance persists")
        settings.appearance = .dark
        check(AppSettings(defaults: defaults).appearance == .dark, "dark appearance persists")
        settings.appearance = .system
        check(AppSettings(defaults: defaults).appearance == .system, "system appearance persists")

        settings.transcriptionProvider = .openAI
        settings.summaryProvider = .local
        var restoredProviders = AppSettings(defaults: defaults)
        check(restoredProviders.transcriptionProvider == .openAI, "transcription provider persists independently")
        check(restoredProviders.summaryProvider == .local, "local summary provider persists independently")
        settings.transcriptionProvider = .local
        settings.summaryProvider = .openAI
        restoredProviders = AppSettings(defaults: defaults)
        check(restoredProviders.transcriptionProvider == .local, "local transcription provider persists independently")
        check(restoredProviders.summaryProvider == .openAI, "summary provider persists independently")

        check(
            AppSettings(defaults: defaults).automaticallyGenerateSummary,
            "automatic summary setting persists"
        )
        let restoredSettings = AppSettings(defaults: defaults)
        check(restoredSettings.appearance == .system, "appearance setting persists")
        check(restoredSettings.transcriptionProvider == .local, "transcription provider persists")
        check(restoredSettings.summaryProvider == .openAI, "summary provider persists")
        check(restoredSettings.usesCustomSummaryPrompt, "custom prompt toggle persists")
        check(
            restoredSettings.customSummaryPrompt == "Liste riscos e bloqueios.",
            "custom prompt text persists"
        )
        check(
            restoredSettings.activeCustomSummaryPrompt == "Liste riscos e bloqueios.",
            "enabled custom prompt becomes active"
        )

        print("Summary checks passed")
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ name: String) {
        guard condition() else {
            fputs("Summary check failed: \(name)\n", stderr)
            exit(1)
        }
    }
}
