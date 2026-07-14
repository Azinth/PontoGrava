import Foundation

enum SummaryLanguage: Equatable, Sendable {
    case portugueseBrazil
    case englishUS
    case transcript

    static func detect(in transcript: String) -> SummaryLanguage {
        guard let languageLine = transcript.split(separator: "\n", omittingEmptySubsequences: false)
            .first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("Idioma:") }) else {
            return .transcript
        }

        let value = languageLine
            .dropFirst("Idioma:".count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if value == "pt" || value.hasPrefix("pt-") || value.contains("portugu") {
            return .portugueseBrazil
        }
        if value == "en" || value.hasPrefix("en-") || value.contains("english") || value.contains("ingl") {
            return .englishUS
        }
        return .transcript
    }

    var locale: Locale? {
        switch self {
        case .portugueseBrazil: Locale(identifier: "pt_BR")
        case .englishUS: Locale(identifier: "en_US")
        case .transcript: nil
        }
    }

    private var languageInstruction: String {
        switch self {
        case .portugueseBrazil:
            "The person's locale is pt_BR. You MUST respond in Brazilian Portuguese."
        case .englishUS:
            "The person's locale is en_US. You MUST respond in U.S. English."
        case .transcript:
            "You MUST respond in the dominant language of the transcript."
        }
    }

    var instructions: String {
        return """
        \(languageInstruction)
        Summarize only facts explicitly present in the transcript. NEVER invent work, decisions, owners, deadlines, names, or action items.
        Classify every fact into exactly one category:
        - Completed work: work already performed or progress already achieved by each participant. Past statements such as "fiz", "removi", "corrigi", "subi", "abri uma PR", or "foi resolvido" belong here. If a named participant explicitly reports no updates, record that fact here.
        - Decisions: only decisions or agreements explicitly made by the team in this meeting. A personal plan or status update is not a decision.
        - Pending work: future intentions, promised next steps, tests still to run, and incomplete work. Statements such as "vou", "irei", "preciso", "falta", "vamos testar", or "estou para fazer" belong here.
        Do not rewrite completed work in the future tense. Do not report pending work as completed. Start each completed-work item with the participant name or names stated in the transcript. Preserve actor attribution: do not credit work to someone merely because their name appears nearby, and list every explicitly stated participant for shared work. Combine facts so each participant or explicitly named group appears at most once per category. NEVER repeat a fact or list item. Include an owner for pending work only when the transcript makes the owner explicit. Return an empty list when a category has no explicit facts.
        """
    }

    func customInstructions(_ prompt: String) -> String {
        """
        \(languageInstruction)
        Use only facts explicitly present in the transcript. NEVER invent names, decisions, owners, deadlines, quotes, or action items.
        Follow the user's summary instructions below. The transcript will be supplied separately.

        USER'S SUMMARY INSTRUCTIONS:
        \(prompt)
        """
    }

    var summaryTitle: String {
        self == .englishUS ? "Meeting Summary" : "Resumo da reunião"
    }

    var completedWorkTitle: String {
        self == .englishUS ? "What was done" : "O que foi feito"
    }

    var decisionsTitle: String {
        self == .englishUS ? "What was decided" : "O que foi definido"
    }

    var pendingWorkTitle: String {
        self == .englishUS ? "What is pending" : "O que está pendente"
    }

    var noCompletedWorkText: String {
        self == .englishUS ? "No completed work identified." : "Nenhum trabalho concluído identificado."
    }

    var noDecisionsText: String {
        self == .englishUS ? "No explicit decisions identified." : "Nenhuma decisão explícita identificada."
    }

    var noPendingWorkText: String {
        self == .englishUS ? "No explicit pending work identified." : "Nenhuma pendência explícita identificada."
    }
}

struct MeetingSummary: Equatable, Sendable {
    let completedWork: [String]
    let decisions: [String]
    let pendingWork: [String]
}

enum SummaryPrompt {
    static let maximumCustomPromptCharacters = 4_000

    static func transcriptSection(_ text: String) -> String {
        """
        Summarize this section of a meeting transcript. Preserve participant names and separate completed work from decisions and pending work according to the instructions.

        TRANSCRIPT SECTION:
        \(text)
        """
    }

    static func consolidation(_ text: String) -> String {
        """
        Consolidate these partial meeting summaries into one factual sync summary. Remove repetition without changing completed work into pending work or pending work into completed work.

        PARTIAL SUMMARIES:
        \(text)
        """
    }

    static func customTranscriptSection(_ text: String) -> String {
        """
        Create the requested summary using only this meeting transcript section.

        TRANSCRIPT SECTION:
        \(text)
        """
    }

    static func customConsolidation(_ text: String) -> String {
        """
        Consolidate these partial summaries into one final summary that follows the user's instructions. Remove repetition and do not add facts.

        PARTIAL SUMMARIES:
        \(text)
        """
    }
}

enum SummaryFormatter {
    static func markdown(_ summary: MeetingSummary, language: SummaryLanguage) -> String {
        let completedWork = bullets(summary.completedWork, emptyText: language.noCompletedWorkText)
        let decisions = bullets(summary.decisions, emptyText: language.noDecisionsText)
        let pendingWork = bullets(summary.pendingWork, emptyText: language.noPendingWorkText)
        return """
        # \(language.summaryTitle)

        ## \(language.completedWorkTitle)

        \(completedWork)

        ## \(language.decisionsTitle)

        \(decisions)

        ## \(language.pendingWorkTitle)

        \(pendingWork)
        """ + "\n"
    }

    static func consolidationText(_ summary: MeetingSummary) -> String {
        """
        COMPLETED WORK:
        \(summary.completedWork.joined(separator: "\n"))
        DECISIONS:
        \(summary.decisions.joined(separator: "\n"))
        PENDING WORK:
        \(summary.pendingWork.joined(separator: "\n"))
        """
    }

    static func customMarkdown(_ text: String) -> String {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "" : value + "\n"
    }

    private static func bullets(_ values: [String], emptyText: String) -> String {
        let lines = values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return (lines.isEmpty ? [emptyText] : lines)
            .map { "- \($0)" }
            .joined(separator: "\n")
    }
}

enum TranscriptChunker {
    static func chunks(_ text: String, maxCharacters: Int = 6_000) -> [String] {
        guard maxCharacters > 0 else { return [] }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .flatMap { split(String($0), maxCharacters: maxCharacters) }
        var result: [String] = []
        var current = ""

        for line in lines {
            let candidate = current.isEmpty ? line : current + "\n" + line
            if candidate.count > maxCharacters, !current.isEmpty {
                result.append(current)
                current = line
            } else {
                current = candidate
            }
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.append(current)
        }
        return result
    }

    private static func split(_ line: String, maxCharacters: Int) -> [String] {
        guard line.count > maxCharacters else { return [line] }
        var remaining = line[...]
        var result: [String] = []

        while remaining.count > maxCharacters {
            let limit = remaining.index(remaining.startIndex, offsetBy: maxCharacters)
            let prefix = remaining[..<limit]
            let splitIndex = prefix.lastIndex(where: { $0.isWhitespace }) ?? limit
            result.append(String(remaining[..<splitIndex]).trimmingCharacters(in: .whitespaces))
            remaining = remaining[splitIndex...].drop(while: { $0.isWhitespace })
        }
        if !remaining.isEmpty { result.append(String(remaining)) }
        return result
    }
}

enum SummaryGenerationPolicy {
    static func shouldWrite(summaryExists: Bool, overwrite: Bool) -> Bool {
        overwrite || !summaryExists
    }
}
