import Foundation
import FoundationModels

enum SummaryError: LocalizedError {
    case unsupportedOS
    case deviceNotEligible
    case appleIntelligenceDisabled
    case modelNotReady
    case unsupportedLanguage(String)
    case missingTranscript
    case emptyTranscript
    case emptyResponse
    case invalidModelOutput
    case customPromptTooLong

    var errorDescription: String? {
        switch self {
        case .unsupportedOS:
            "Os resumos por IA exigem macOS 26 ou mais recente. Para reuniões em português, use macOS 26.1 ou mais recente."
        case .deviceNotEligible:
            "Este Mac não é compatível com o modelo local do Apple Intelligence."
        case .appleIntelligenceDisabled:
            "Ative o Apple Intelligence nos Ajustes do Sistema para gerar resumos locais."
        case .modelNotReady:
            "O modelo do Apple Intelligence ainda está sendo preparado. Aguarde o download terminar e tente novamente."
        case let .unsupportedLanguage(locale):
            "O modelo local ainda não oferece suporte ao idioma \(locale) neste macOS."
        case .missingTranscript:
            "A transcrição desta reunião não foi encontrada."
        case .emptyTranscript:
            "A transcrição está vazia e não pode ser resumida."
        case .emptyResponse:
            "O modelo terminou sem produzir um resumo."
        case .invalidModelOutput:
            "O modelo local não conseguiu estruturar o resumo. Tente gerar novamente."
        case .customPromptTooLong:
            "O prompt personalizado é muito longo. Reduza-o para até \(SummaryPrompt.maximumCustomPromptCharacters) caracteres."
        }
    }
}

@available(macOS 26.0, *)
@Generable(description: "A factual sync meeting summary that separates completed and pending work")
private struct GeneratedMeetingSummary {
    @Guide(description: "Completed work grouped by participant; every item starts with the explicit participant name and contains only work already done", .maximumCount(12))
    var completedWork: [String]

    @Guide(description: "Only decisions or agreements explicitly made by the team during this meeting", .maximumCount(12))
    var decisions: [String]

    @Guide(description: "Only future, incomplete, or still-pending work; include owner or deadline only when explicitly stated", .maximumCount(12))
    var pendingWork: [String]
}

actor SummaryService {
    nonisolated static var unavailabilityMessage: String? {
        guard #available(macOS 26.0, *) else {
            return SummaryError.unsupportedOS.localizedDescription
        }
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case let .unavailable(reason):
            return availabilityError(reason).localizedDescription
        }
    }

    func generate(
        transcriptURL: URL,
        folderURL: URL,
        overwrite: Bool,
        customPrompt: String?,
        provider: AIProvider,
        apiKey: String?,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> URL {
        let summaryURL = folderURL.appendingPathComponent("resumo.md")
        let exists = FileManager.default.fileExists(atPath: summaryURL.path)
        guard SummaryGenerationPolicy.shouldWrite(summaryExists: exists, overwrite: overwrite) else {
            return summaryURL
        }
        guard FileManager.default.fileExists(atPath: transcriptURL.path) else {
            throw SummaryError.missingTranscript
        }
        let transcript = try String(contentsOf: transcriptURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else { throw SummaryError.emptyTranscript }
        let prompt = customPrompt?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let prompt, prompt.count > SummaryPrompt.maximumCustomPromptCharacters {
            throw SummaryError.customPromptTooLong
        }
        let activePrompt = prompt?.isEmpty == false ? prompt : nil
        let markdown: String
        switch provider {
        case .local:
            guard #available(macOS 26.0, *) else { throw SummaryError.unsupportedOS }
            progress(0.05, "Verificando o modelo local…")
            markdown = try await generateAvailable(
                transcript: transcript,
                customPrompt: activePrompt,
                progress: progress
            )
        case .openAI:
            guard let apiKey, !apiKey.isEmpty else { throw OpenAIError.missingAPIKey }
            progress(0.05, "Conectando à OpenAI…")
            markdown = try await generateOpenAI(
                transcript: transcript,
                customPrompt: activePrompt,
                apiKey: apiKey,
                progress: progress
            )
        }
        try markdown.write(to: summaryURL, atomically: true, encoding: .utf8)
        progress(1, "Resumo concluído")
        return summaryURL
    }

    @available(macOS 26.0, *)
    private func generateAvailable(
        transcript: String,
        customPrompt: String?,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> String {
        let model = SystemLanguageModel.default
        if case let .unavailable(reason) = model.availability {
            throw Self.availabilityError(reason)
        }

        let language = SummaryLanguage.detect(in: transcript)
        if let locale = language.locale, !model.supportsLocale(locale) {
            throw SummaryError.unsupportedLanguage(locale.identifier)
        }

        let context = customPrompt.map { $0 + "\n" + transcript } ?? transcript
        let chunks: [String]
        if fitsContext(context) {
            chunks = [transcript]
        } else {
            chunks = TranscriptChunker.chunks(transcript)
        }

        if let customPrompt {
            return try await generateCustom(
                chunks: chunks,
                customPrompt: customPrompt,
                language: language,
                progress: progress
            )
        }

        let summary = try await generateDefault(
            chunks: chunks,
            language: language,
            progress: progress
        )
        return SummaryFormatter.markdown(summary, language: language)
    }

    private func generateOpenAI(
        transcript: String,
        customPrompt: String?,
        apiKey: String,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> String {
        let language = SummaryLanguage.detect(in: transcript)
        let chunks = TranscriptChunker.chunks(transcript, maxCharacters: 40_000)
        let client = OpenAIClient(apiKey: apiKey)
        if let customPrompt {
            return try await generateOpenAICustom(
                chunks: chunks,
                customPrompt: customPrompt,
                language: language,
                client: client,
                progress: progress
            )
        }
        let summary = try await generateOpenAIDefault(
            chunks: chunks,
            language: language,
            client: client,
            progress: progress
        )
        return SummaryFormatter.markdown(summary, language: language)
    }

    private func generateOpenAIDefault(
        chunks: [String],
        language: SummaryLanguage,
        client: OpenAIClient,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> MeetingSummary {
        progress(0.12, chunks.count == 1 ? "Gerando o resumo…" : "Resumindo \(chunks.count) trechos…")
        var summaries: [MeetingSummary] = []
        for (index, chunk) in chunks.enumerated() {
            summaries.append(try await client.meetingSummary(
                instructions: language.instructions,
                prompt: SummaryPrompt.transcriptSection(chunk),
                maximumOutputTokens: chunks.count == 1 ? 1_000 : 600
            ))
            let fraction = Double(index + 1) / Double(chunks.count)
            progress(0.12 + fraction * 0.58, "Resumindo trecho \(index + 1) de \(chunks.count)…")
        }

        while summaries.count > 1 {
            let combined = summaries
                .map(SummaryFormatter.consolidationText)
                .joined(separator: "\n---\n")
            let batches = TranscriptChunker.chunks(combined, maxCharacters: 40_000)
            if batches.count == 1 {
                progress(0.82, "Consolidando o resumo…")
                return try await client.meetingSummary(
                    instructions: language.instructions,
                    prompt: SummaryPrompt.consolidation(combined),
                    maximumOutputTokens: 1_000
                )
            }

            var consolidated: [MeetingSummary] = []
            for batch in batches {
                consolidated.append(try await client.meetingSummary(
                    instructions: language.instructions,
                    prompt: SummaryPrompt.consolidation(batch),
                    maximumOutputTokens: 600
                ))
            }
            summaries = consolidated
        }
        guard let summary = summaries.first else { throw SummaryError.emptyResponse }
        return summary
    }

    private func generateOpenAICustom(
        chunks: [String],
        customPrompt: String,
        language: SummaryLanguage,
        client: OpenAIClient,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> String {
        let instructions = language.customInstructions(customPrompt)
        progress(0.12, chunks.count == 1 ? "Gerando o resumo personalizado…" : "Resumindo \(chunks.count) trechos…")
        var summaries: [String] = []
        for (index, chunk) in chunks.enumerated() {
            summaries.append(try await client.text(
                instructions: instructions,
                prompt: SummaryPrompt.customTranscriptSection(chunk),
                maximumOutputTokens: chunks.count == 1 ? 1_200 : 700
            ))
            let fraction = Double(index + 1) / Double(chunks.count)
            progress(0.12 + fraction * 0.58, "Resumindo trecho \(index + 1) de \(chunks.count)…")
        }

        while summaries.count > 1 {
            let combined = summaries.joined(separator: "\n\n---\n\n")
            let batches = TranscriptChunker.chunks(combined, maxCharacters: 40_000)
            if batches.count == 1 {
                progress(0.82, "Consolidando o resumo personalizado…")
                return SummaryFormatter.customMarkdown(try await client.text(
                    instructions: instructions,
                    prompt: SummaryPrompt.customConsolidation(combined),
                    maximumOutputTokens: 1_200
                ))
            }

            var consolidated: [String] = []
            for batch in batches {
                consolidated.append(try await client.text(
                    instructions: instructions,
                    prompt: SummaryPrompt.customConsolidation(batch),
                    maximumOutputTokens: 700
                ))
            }
            summaries = consolidated
        }
        guard let summary = summaries.first else { throw SummaryError.emptyResponse }
        let markdown = SummaryFormatter.customMarkdown(summary)
        guard !markdown.isEmpty else { throw SummaryError.emptyResponse }
        return markdown
    }

    @available(macOS 26.0, *)
    private func generateDefault(
        chunks: [String],
        language: SummaryLanguage,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> MeetingSummary {
        progress(0.12, chunks.count == 1 ? "Gerando o resumo…" : "Resumindo \(chunks.count) trechos…")
        var summaries: [MeetingSummary] = []
        for (index, chunk) in chunks.enumerated() {
            summaries.append(try await generateOne(
                prompt: SummaryPrompt.transcriptSection(chunk),
                language: language,
                maximumResponseTokens: chunks.count == 1 ? 700 : 320
            ))
            let fraction = Double(index + 1) / Double(chunks.count)
            progress(0.12 + fraction * 0.58, "Resumindo trecho \(index + 1) de \(chunks.count)…")
        }

        while summaries.count > 1 {
            let combined = summaries
                .map(SummaryFormatter.consolidationText)
                .joined(separator: "\n---\n")
            if fitsContext(combined) {
                progress(0.82, "Consolidando o resumo…")
                return try await generateOne(
                    prompt: SummaryPrompt.consolidation(combined),
                    language: language,
                    maximumResponseTokens: 700
                )
            }

            let batches = TranscriptChunker.chunks(combined)
            summaries = try await batches.asyncMap { batch in
                try await generateOne(
                    prompt: SummaryPrompt.consolidation(batch),
                    language: language,
                    maximumResponseTokens: 320
                )
            }
        }

        guard let summary = summaries.first else { throw SummaryError.emptyResponse }
        return summary
    }

    @available(macOS 26.0, *)
    private func generateCustom(
        chunks: [String],
        customPrompt: String,
        language: SummaryLanguage,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> String {
        let instructions = language.customInstructions(customPrompt)
        progress(0.12, chunks.count == 1 ? "Gerando o resumo personalizado…" : "Resumindo \(chunks.count) trechos…")

        var summaries: [String] = []
        for (index, chunk) in chunks.enumerated() {
            summaries.append(try await generateCustomOne(
                prompt: SummaryPrompt.customTranscriptSection(chunk),
                instructions: instructions,
                maximumResponseTokens: chunks.count == 1 ? 700 : 400
            ))
            let fraction = Double(index + 1) / Double(chunks.count)
            progress(0.12 + fraction * 0.58, "Resumindo trecho \(index + 1) de \(chunks.count)…")
        }

        while summaries.count > 1 {
            let combined = summaries.joined(separator: "\n\n---\n\n")
            if fitsContext(customPrompt + "\n" + combined) {
                progress(0.82, "Consolidando o resumo personalizado…")
                return SummaryFormatter.customMarkdown(try await generateCustomOne(
                    prompt: SummaryPrompt.customConsolidation(combined),
                    instructions: instructions,
                    maximumResponseTokens: 700
                ))
            }

            summaries = try await TranscriptChunker.chunks(combined).asyncMap { batch in
                try await generateCustomOne(
                    prompt: SummaryPrompt.customConsolidation(batch),
                    instructions: instructions,
                    maximumResponseTokens: 400
                )
            }
        }

        guard let summary = summaries.first else { throw SummaryError.emptyResponse }
        let markdown = SummaryFormatter.customMarkdown(summary)
        guard !markdown.isEmpty else { throw SummaryError.emptyResponse }
        return markdown
    }

    @available(macOS 26.0, *)
    private func generateOne(
        prompt: String,
        language: SummaryLanguage,
        maximumResponseTokens: Int
    ) async throws -> MeetingSummary {
        for attempt in 0..<2 {
            do {
                let response = try await LanguageModelSession(instructions: language.instructions).respond(
                    to: prompt,
                    generating: GeneratedMeetingSummary.self,
                    options: GenerationOptions(
                        sampling: attempt == 0 ? .greedy : .random(top: 20),
                        maximumResponseTokens: maximumResponseTokens
                    )
                )
                let content = response.content
                return MeetingSummary(
                    completedWork: content.completedWork,
                    decisions: content.decisions,
                    pendingWork: content.pendingWork
                )
            } catch let error as LanguageModelSession.GenerationError {
                guard case .decodingFailure = error else { throw error }
                guard attempt == 0 else { throw SummaryError.invalidModelOutput }
            }
        }
        throw SummaryError.invalidModelOutput
    }

    @available(macOS 26.0, *)
    private func generateCustomOne(
        prompt: String,
        instructions: String,
        maximumResponseTokens: Int
    ) async throws -> String {
        let response = try await LanguageModelSession(instructions: instructions).respond(
            to: prompt,
            options: GenerationOptions(
                sampling: .random(top: 20),
                maximumResponseTokens: maximumResponseTokens
            )
        )
        let content = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { throw SummaryError.emptyResponse }
        return content
    }

    @available(macOS 26.0, *)
    private func fitsContext(_ text: String) -> Bool { text.count <= 6_000 }

    @available(macOS 26.0, *)
    nonisolated private static func availabilityError(
        _ reason: SystemLanguageModel.Availability.UnavailableReason
    ) -> SummaryError {
        switch reason {
        case .deviceNotEligible: .deviceNotEligible
        case .appleIntelligenceNotEnabled: .appleIntelligenceDisabled
        case .modelNotReady: .modelNotReady
        @unknown default: .modelNotReady
        }
    }
}

private extension Array {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var values: [T] = []
        values.reserveCapacity(count)
        for element in self { values.append(try await transform(element)) }
        return values
    }
}
