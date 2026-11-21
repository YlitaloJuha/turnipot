import Foundation

// AskUserQuestion / ExitPlanMode answered from the notch.
//
// Shapes verified against https://code.claude.com/docs/en/hooks ("AskUserQuestion", "ExitPlanMode",
// "Tools that require user interaction") and real transcripts on this machine:
//  AskUserQuestion tool_input: {"questions":[{"question","header","options":[{"label","description"}],
//                               "multiSelect":Bool}]}  (1-4 questions; answers/annotations/metadata optional)
//  Answer: allow + updatedInput = original input + {"answers":{"<question text>":"<label>"}};
//          multi-select labels joined with ", "; a free-text ("Other") answer is the text itself.
//  ExitPlanMode tool_input (as hooks see it): {"plan":"<markdown>","planFilePath":"..."} (+ deprecated
//               allowedPrompts). Approve: allow + updatedInput = the input unchanged (+ optional
//               setMode); keep planning: deny + message (the feedback).

/// What a pending hook request asks of the user.
public enum RequestKind: String, Equatable, Sendable {
    case permission, question, plan

    public init(toolName: String) {
        switch toolName {
        case "AskUserQuestion": self = .question
        case "ExitPlanMode": self = .plan
        default: self = .permission
        }
    }

    /// Seconds the app waits for an answer before giving the prompt back to the terminal.
    public var uiTimeout: TimeInterval {
        self == .permission ? NotchConstants.permissionUITimeout : NotchConstants.questionUITimeout
    }
}

public struct AskOption: Equatable, Sendable {
    public var label: String
    public var description: String
    public init(label: String, description: String = "") { self.label = label; self.description = description }
}

public struct AskQuestion: Equatable, Sendable, Identifiable {
    public var question: String
    public var header: String
    public var options: [AskOption]
    public var multiSelect: Bool
    public var id: String { question }

    public init(question: String, header: String = "", options: [AskOption], multiSelect: Bool = false) {
        self.question = question; self.header = header; self.options = options; self.multiSelect = multiSelect
    }

    /// Questions from an AskUserQuestion `tool_input`; nil when the input isn't usable (no
    /// questions, a question without text, duplicate question texts — answers are keyed by text).
    public static func parse(_ toolInput: JSONValue) -> [AskQuestion]? {
        guard case .array(let items)? = toolInput["questions"], !items.isEmpty else { return nil }
        var out: [AskQuestion] = []
        for item in items {
            guard let q = item["question"]?.stringValue,
                  !q.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            var options: [AskOption] = []
            if case .array(let opts)? = item["options"] {
                for o in opts {
                    if let label = o["label"]?.stringValue, !label.isEmpty {
                        options.append(AskOption(label: label, description: o["description"]?.stringValue ?? ""))
                    } else if let label = o.stringValue, !label.isEmpty {
                        options.append(AskOption(label: label))
                    }
                }
            }
            var multi = false
            if case .bool(let b)? = item["multiSelect"] { multi = b }
            out.append(AskQuestion(question: q, header: item["header"]?.stringValue ?? "", options: options, multiSelect: multi))
        }
        guard Set(out.map(\.question)).count == out.count else { return nil }
        return out
    }
}

/// The user's pick for one question: chosen option indices and / or free text ("Other…").
public struct QuestionSelection: Equatable, Sendable {
    public var options: Set<Int>
    public var other: String?

    public init(options: Set<Int> = [], other: String? = nil) { self.options = options; self.other = other }

    public var trimmedOther: String? {
        guard let t = other?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }
    public var isAnswered: Bool { !options.isEmpty || trimmedOther != nil }

    /// Single-select: picking an option replaces the previous pick (and clears "Other");
    /// multi-select: toggles it.
    public mutating func toggle(_ index: Int, multiSelect: Bool) {
        if multiSelect {
            if options.contains(index) { options.remove(index) } else { options.insert(index) }
        } else {
            options = options == [index] ? [] : [index]
            other = nil
        }
    }
}

public enum QuestionAnswers {
    /// Answer text for one question: chosen labels in option order, then the free text, joined
    /// with ", " (the docs: "Multi-select answers join labels with commas"). nil = unanswered.
    public static func answer(for q: AskQuestion, _ s: QuestionSelection) -> String? {
        var parts = s.options.sorted().compactMap { q.options.indices.contains($0) ? q.options[$0].label : nil }
        if !q.multiSelect, parts.count > 1 { parts = [parts[0]] }
        if let t = s.trimmedOther {
            if q.multiSelect { parts.append(t) } else { parts = [t] }
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// `answers` map (question text -> answer); nil unless every question is answered.
    public static func answers(_ questions: [AskQuestion], _ selections: [QuestionSelection]) -> [String: String]? {
        guard selections.count == questions.count else { return nil }
        var out: [String: String] = [:]
        for (q, s) in zip(questions, selections) {
            guard let a = answer(for: q, s) else { return nil }
            out[q.question] = a
        }
        return out
    }

    /// `updatedInput` for the hook: the original tool input (questions echoed unchanged) plus
    /// `answers`.
    public static func updatedInput(original: JSONValue, answers: [String: String]) -> JSONValue {
        var obj = original.objectValue ?? [:]
        obj["answers"] = .object(answers.mapValues { .string($0) })
        return .object(obj)
    }
}

/// Permission mode to continue in after approving a plan from the notch (the terminal's
/// "Yes, and use auto mode" / "Yes, auto-accept edits" / "Yes, manually approve edits").
public enum PlanApprovalMode: String, CaseIterable, Equatable, Sendable {
    /// Leave plan mode, ask before edits (the hook sends setMode "default").
    case manual = "default"
    case acceptEdits
    case auto

    public var title: String {
        switch self {
        case .manual: return "Approve, ask before edits"
        case .acceptEdits: return "Approve, auto-accept edits"
        case .auto: return "Approve, auto mode"
        }
    }
}

public struct PlanContent: Equatable, Sendable {
    public var plan: String
    public var filePath: String?

    /// From an ExitPlanMode `tool_input`; nil without a non-empty `plan`.
    public static func parse(_ toolInput: JSONValue) -> PlanContent? {
        guard let p = toolInput["plan"]?.stringValue, !p.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return PlanContent(plan: p, filePath: toolInput["planFilePath"]?.stringValue ?? toolInput["filePath"]?.stringValue)
    }

    /// First heading (or first line) of the plan, for titles.
    public var title: String {
        for b in MarkdownBlocks.parse(plan) {
            switch b {
            case .heading(_, let t): return t
            case .paragraph(let t): return String(t.split(separator: "\n").first ?? "")
            default: continue
            }
        }
        return "Plan"
    }

    /// Deny message for "Keep planning…": tells Claude to stay in plan mode and revise.
    public static func feedbackMessage(_ feedback: String) -> String {
        let t = feedback.trimmingCharacters(in: .whitespacesAndNewlines)
        let head = "The user wants to keep planning (answered from Turnipot). Stay in plan mode and revise the plan."
        return t.isEmpty ? head : head + " The user said:\n" + t
    }
}
