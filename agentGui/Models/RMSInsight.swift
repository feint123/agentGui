import Foundation

/// Long-term RMS insight categories that are allowed to survive across tasks.
///
/// The kind controls how an insight is interpreted during selection and prompt
/// composition:
/// - `constraint`: A stable rule or boundary that should shape future actions.
/// - `counterexample`: A remembered failure mode that should block repeating a bad path.
/// - `tactic`: A reusable action pattern that is often worth trying again.
enum RMSInsightKind: String, Codable, Equatable, Sendable {
    case constraint
    case counterexample
    case tactic
}

/// A reusable, decision-relevant memory item for the simplified RMS pipeline.
///
/// `RMSInsight` is intentionally narrower than the older record-centric memory
/// model. It stores only the kinds of information that can materially change a
/// future action choice, such as a rule to obey, a mistake to avoid, or a tactic
/// worth reusing.
///
/// Typical lifecycle:
/// 1. The agent extracts a candidate insight from a completed round.
/// 2. The insight is persisted with a scope and confidence.
/// 3. A later task loads scoped insights.
/// 4. `RMSSelector` decides whether this insight should influence the current task.
/// 5. `RMSPromptComposer` renders the selected insight into the bootstrap prompt.
struct RMSInsight: Codable, Equatable, Sendable, Identifiable {
    /// Stable identifier for persistence, updates, and deduplication.
    ///
    /// This value should remain stable when an insight is being updated in place.
    /// If a new identifier is generated, the store will treat it as a distinct insight.
    var id: String

    /// Semantic category of the insight.
    ///
    /// The kind determines both display semantics and selection priority.
    /// For example, constraints are typically surfaced before tactics because they
    /// block invalid actions rather than merely suggesting useful ones.
    var kind: RMSInsightKind

    /// Human-readable summary of the memory item itself.
    ///
    /// This should be concise but specific enough to stand on its own in a prompt.
    /// Examples:
    /// - "Inspect current failure output before editing"
    /// - "Edit-first caused regression in this build flow"
    /// - "Run a targeted xcodebuild invocation first"
    var summary: String

    /// Short description of when this insight is relevant.
    ///
    /// This is used as a lightweight applicability hint by `RMSSelector`.
    /// It can describe a task domain, failure shape, tool, or situation, such as:
    /// - `coding`
    /// - `xcodebuild`
    /// - `swift build triage`
    /// - `creative writing`
    var appliesWhen: String

    /// Explanation of how this insight changes the agent's decision-making.
    ///
    /// This field captures the actionable effect of the insight rather than the
    /// raw fact alone. Good values describe how the next action ordering changes,
    /// what should now be blocked, or what should be prioritized instead.
    var changesDecision: String

    /// Replacement action to take instead of a known bad path.
    ///
    /// This is most useful for `counterexample` insights. It can be `nil` for
    /// `constraint` and `tactic` insights when there is no explicit replacement step.
    var replacementAction: String?

    /// Evidence references that justify why this insight exists.
    ///
    /// These are lightweight provenance markers, such as round IDs, tool outputs,
    /// or synthetic source tags like `tool:memory_write`. They help later prompt
    /// rendering explain where the memory came from without storing full raw logs.
    var evidenceRefs: [String]

    /// Scope that limits where the insight can be reused.
    ///
    /// Examples:
    /// - `.user`: reusable across all work
    /// - `.workspace`: reusable within one workspace
    /// - `.session`: only meaningful within one ongoing task session
    ///
    /// `nil` means the insight is not explicitly scoped and should be treated as broadly reusable.
    var scope: MemoryScope?

    /// Confidence score for whether this insight is reliable enough to reuse.
    ///
    /// Expected range is usually `0...1`. Higher values indicate that the insight is
    /// more trustworthy and therefore more likely to be selected and persisted.
    var confidence: Double

    /// Timestamp of the most recent creation or update.
    ///
    /// The store uses this to sort newer insights ahead of older ones when needed.
    var updatedAt: Date?

    /// Creates a reusable RMS insight with full control over all fields.
    ///
    /// - Parameters:
    ///   - id: Stable identifier used for persistence and overwrite behavior.
    ///   - kind: Semantic category of the insight.
    ///   - summary: Short human-readable description of the remembered rule, failure, or tactic.
    ///   - appliesWhen: Applicability hint used to decide whether the insight matches a future task.
    ///   - changesDecision: Description of how the insight should alter action selection.
    ///   - replacementAction: Optional safer action to take instead of a previously failed path.
    ///   - evidenceRefs: Lightweight provenance references that justify the insight.
    ///   - scope: Optional reuse boundary for the insight.
    ///   - confidence: Reliability score for later selection and persistence logic.
    ///   - updatedAt: Optional explicit timestamp; if omitted, the store may fill one in during persistence.
    init(
        id: String,
        kind: RMSInsightKind,
        summary: String,
        appliesWhen: String,
        changesDecision: String,
        replacementAction: String? = nil,
        evidenceRefs: [String] = [],
        scope: MemoryScope? = nil,
        confidence: Double = 1,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.kind = kind
        self.summary = summary
        self.appliesWhen = appliesWhen
        self.changesDecision = changesDecision
        self.replacementAction = replacementAction
        self.evidenceRefs = evidenceRefs
        self.scope = scope
        self.confidence = confidence
        self.updatedAt = updatedAt
    }

    /// Convenience constructor for a stable behavioral constraint.
    ///
    /// Use this when the remembered content is primarily a rule or boundary that
    /// should constrain future actions, for example "inspect before editing" or
    /// "verify with direct evidence before declaring success".
    ///
    /// - Parameters:
    ///   - id: Stable identifier for the persisted insight.
    ///   - summary: Short statement of the constraint itself.
    ///   - appliesWhen: Situation in which this constraint should apply.
    ///   - changesDecision: How the constraint should alter or block future actions.
    ///   - evidenceRefs: Provenance references supporting the constraint.
    ///   - scope: Optional reuse boundary.
    ///   - confidence: Confidence that the constraint is valid and worth reusing.
    /// - Returns: A constraint-typed `RMSInsight`.
    static func constraint(
        id: String,
        summary: String,
        appliesWhen: String,
        changesDecision: String,
        evidenceRefs: [String] = [],
        scope: MemoryScope? = nil,
        confidence: Double = 1
    ) -> RMSInsight {
        RMSInsight(
            id: id,
            kind: .constraint,
            summary: summary,
            appliesWhen: appliesWhen,
            changesDecision: changesDecision,
            evidenceRefs: evidenceRefs,
            scope: scope,
            confidence: confidence
        )
    }

    /// Convenience constructor for a remembered failure pattern.
    ///
    /// Use this when you want to preserve a concrete bad path that should be
    /// avoided later. The paired `replacementAction` tells the agent what to do
    /// instead when the same problem shape appears again.
    ///
    /// - Parameters:
    ///   - id: Stable identifier for the persisted insight.
    ///   - summary: Concise description of the failed or falsified path.
    ///   - appliesWhen: Situation in which this failure pattern is relevant.
    ///   - changesDecision: Description of how this memory blocks or reroutes action selection.
    ///   - replacementAction: Preferred alternative to the bad path.
    ///   - evidenceRefs: Provenance references supporting the counterexample.
    ///   - scope: Optional reuse boundary.
    ///   - confidence: Confidence that the failure pattern is real and reusable.
    /// - Returns: A counterexample-typed `RMSInsight`.
    static func counterexample(
        id: String,
        summary: String,
        appliesWhen: String,
        changesDecision: String,
        replacementAction: String,
        evidenceRefs: [String] = [],
        scope: MemoryScope? = nil,
        confidence: Double = 1
    ) -> RMSInsight {
        RMSInsight(
            id: id,
            kind: .counterexample,
            summary: summary,
            appliesWhen: appliesWhen,
            changesDecision: changesDecision,
            replacementAction: replacementAction,
            evidenceRefs: evidenceRefs,
            scope: scope,
            confidence: confidence
        )
    }

    /// Convenience constructor for a reusable tactic.
    ///
    /// Use this when the memory is not a hard rule and not a failure warning, but
    /// instead a useful action pattern that has a good chance of helping again in
    /// similar situations.
    ///
    /// - Parameters:
    ///   - id: Stable identifier for the persisted insight.
    ///   - summary: Short description of the tactic to reuse.
    ///   - appliesWhen: Situation in which this tactic is likely to help.
    ///   - changesDecision: Description of how the tactic should influence future action ordering.
    ///   - evidenceRefs: Provenance references supporting the tactic.
    ///   - scope: Optional reuse boundary.
    ///   - confidence: Confidence that the tactic is reusable and worth surfacing.
    /// - Returns: A tactic-typed `RMSInsight`.
    static func tactic(
        id: String,
        summary: String,
        appliesWhen: String,
        changesDecision: String,
        evidenceRefs: [String] = [],
        scope: MemoryScope? = nil,
        confidence: Double = 1
    ) -> RMSInsight {
        RMSInsight(
            id: id,
            kind: .tactic,
            summary: summary,
            appliesWhen: appliesWhen,
            changesDecision: changesDecision,
            evidenceRefs: evidenceRefs,
            scope: scope,
            confidence: confidence
        )
    }
}