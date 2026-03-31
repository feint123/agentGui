import Foundation

enum BriefExtractionState: Equatable, Sendable {
    case idle
    case extracting
    case done
    case failed(String)
}

struct AgentTeamMissionBriefDraft: Equatable, Sendable {
    var rawInput: String
    var objective: String
    var constraintsText: String
    var acceptanceCriteriaText: String
    var mode: AgentTeamMode
    var maxActiveProviders: Int
    var initialContextSummary: String
    var sourceSessionTitle: String
    var roleAssignments: [AgentTeamProviderRoleAssignment]
    var dispatchPolicy: AgentTeamDispatchPolicy
    var extractionState: BriefExtractionState

    init(
        rawInput: String = "",
        objective: String = "",
        constraintsText: String = "",
        acceptanceCriteriaText: String = "",
        mode: AgentTeamMode = .executionDelivery,
        maxActiveProviders: Int = 2,
        initialContextSummary: String = "",
        sourceSessionTitle: String = "",
        roleAssignments: [AgentTeamProviderRoleAssignment] = [],
        dispatchPolicy: AgentTeamDispatchPolicy = .manualSelection,
        extractionState: BriefExtractionState = .idle
    ) {
        self.rawInput = rawInput
        self.objective = objective
        self.constraintsText = constraintsText
        self.acceptanceCriteriaText = acceptanceCriteriaText
        self.mode = mode
        self.maxActiveProviders = maxActiveProviders
        self.initialContextSummary = initialContextSummary
        self.sourceSessionTitle = sourceSessionTitle
        self.roleAssignments = roleAssignments
        self.dispatchPolicy = dispatchPolicy
        self.extractionState = extractionState
    }
}

extension AgentTeamMissionBriefDraft {
    static func prefilled(from source: Session?) -> Self {
        let sourceTitle = source?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let preview = source?.lastMessagePreview.trimmedNonEmpty
        let seededProvider: ExecutionProviderReference?
        if let persisted = source?.defaultExecutionProviderReference,
           persisted != .builtIn {
            seededProvider = persisted
        } else if let persistedID = source?.defaultExecutionProviderID, !persistedID.isEmpty {
            seededProvider = ExecutionProviderReference.decodePersisted(persistedID)
        } else {
            seededProvider = nil
        }
        let assignments = Self.initialAssignments(seededConductor: seededProvider)
        return Self(
            rawInput: "",
            objective: defaultObjective(for: sourceTitle),
            constraintsText: "",
            acceptanceCriteriaText: "",
            mode: .executionDelivery,
            maxActiveProviders: 2,
            initialContextSummary: defaultContextSummary(sourceTitle: sourceTitle, preview: preview),
            sourceSessionTitle: sourceTitle,
            roleAssignments: assignments,
            dispatchPolicy: seededProvider != nil ? .sourceSessionSeeded : .manualSelection,
            extractionState: .idle
        )
    }

    static func prefilled(fromSourceContext sourceContext: NewSessionMenuAction.SourceContext?) -> Self {
        let sourceTitle = sourceContext?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let seededProvider = sourceContext.flatMap { ctx -> ExecutionProviderReference? in
            let ref = ctx.defaultExecutionProviderReference
            return ref.persistedValue.isEmpty ? nil : ref
        }
        let assignments = Self.initialAssignments(seededConductor: seededProvider)
        return Self(
            rawInput: "",
            objective: defaultObjective(for: sourceTitle),
            constraintsText: "",
            acceptanceCriteriaText: "",
            mode: .executionDelivery,
            maxActiveProviders: 2,
            initialContextSummary: defaultContextSummary(sourceTitle: sourceTitle, preview: nil),
            sourceSessionTitle: sourceTitle,
            roleAssignments: assignments,
            dispatchPolicy: seededProvider != nil ? .sourceSessionSeeded : .manualSelection,
            extractionState: .idle
        )
    }

    /// 初始时若有 seeded provider，自动分配为 conductor+worker；否则空分配
    private static func initialAssignments(
        seededConductor: ExecutionProviderReference?
    ) -> [AgentTeamProviderRoleAssignment] {
        guard let ref = seededConductor else { return [] }
        return [AgentTeamProviderRoleAssignment(providerReference: ref, roles: [.conductor, .worker])]
    }
}

extension AgentTeamMissionBriefDraft {
    func buildBrief() -> AgentTeamMissionBrief {
        AgentTeamMissionBrief(
            objective: resolvedObjective,
            constraints: Self.normalizeLines(from: constraintsText),
            acceptanceCriteria: Self.normalizeLines(from: acceptanceCriteriaText),
            mode: mode,
            dispatchBudget: AgentTeamDispatchBudget(maxActiveProviders: max(1, maxActiveProviders)),
            initialContextSummary: resolvedContextSummary,
            providerPlan: AgentTeamProviderPlan(
                roleAssignments: roleAssignments,
                dispatchPolicy: dispatchPolicy
            )
        )
    }

    /// 为某个 provider 设置或取消某个 role。
    /// conductor 唯一性规则：若 enabled=true 且 role==.conductor，
    /// 先将其他所有 assignment 的 .conductor 移除。
    mutating func setRole(
        _ role: AgentTeamProviderRole,
        for provider: ExecutionProviderReference,
        enabled: Bool
    ) {
        if enabled, role == .conductor {
            for i in roleAssignments.indices {
                roleAssignments[i].roles.remove(.conductor)
            }
        }
        if let idx = roleAssignments.firstIndex(where: { $0.providerReference == provider }) {
            if enabled {
                roleAssignments[idx].roles.insert(role)
            } else {
                roleAssignments[idx].roles.remove(role)
            }
        } else if enabled {
            roleAssignments.append(
                AgentTeamProviderRoleAssignment(providerReference: provider, roles: [role])
            )
        }
    }

    /// 若 provider 不在 assignments 中，追加（roles 为 worker）；否则移除整条 assignment。
    mutating func toggleProviderParticipation(_ provider: ExecutionProviderReference) {
        if let idx = roleAssignments.firstIndex(where: { $0.providerReference == provider }) {
            roleAssignments.remove(at: idx)
            // 若被移除的是 conductor，自动把第一个 worker 提升为 conductor
            if !roleAssignments.contains(where: { $0.isConductor }),
               let first = roleAssignments.indices.first {
                roleAssignments[first].roles.insert(.conductor)
            }
        } else {
            roleAssignments.append(
                AgentTeamProviderRoleAssignment(providerReference: provider, roles: [.worker])
            )
        }
    }

    /// 根据可用 provider 列表过滤 roleAssignments，保证 conductor 始终存在。
    mutating func reconcileProviderOptions(
        _ options: [ExecutionOptionItem],
        sourceDefaultProviderID: String? = nil
    ) {
        let availableIDs = Set(options.filter(\.isEnabled).map(\.id))
        roleAssignments = roleAssignments.filter {
            availableIDs.contains($0.providerReference.persistedValue)
        }
        // 若有 seeded provider 且 assignments 为空，自动追加 conductor
        if roleAssignments.isEmpty,
           let seedID = sourceDefaultProviderID,
           !seedID.isEmpty,
           availableIDs.contains(seedID) {
            let ref = ExecutionProviderReference.decodePersisted(seedID)
            roleAssignments = [AgentTeamProviderRoleAssignment(providerReference: ref, roles: [.conductor, .worker])]
        }
        // 保证至少存在一个 conductor
        if !roleAssignments.contains(where: { $0.isConductor }),
           let first = roleAssignments.indices.first {
            roleAssignments[first].roles.insert(.conductor)
        }
        // 更新 dispatchPolicy
        if let seedID = sourceDefaultProviderID,
           !seedID.isEmpty,
           roleAssignments.first(where: { $0.isConductor })?.providerReference.persistedValue == seedID {
            dispatchPolicy = .sourceSessionSeeded
        } else {
            dispatchPolicy = .manualSelection
        }
    }

    private var resolvedObjective: String {
        let trimmedObjective = objective.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedObjective.isEmpty { return trimmedObjective }
        let trimmedRaw = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedRaw.isEmpty { return trimmedRaw }
        return Self.defaultObjective(for: sourceSessionTitle)
    }

    private var resolvedContextSummary: String {
        initialContextSummary.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? Self.defaultContextSummary(sourceTitle: sourceSessionTitle, preview: nil)
    }

    private static func defaultObjective(for sourceTitle: String) -> String {
        guard let sourceTitle = sourceTitle.trimmedNonEmpty else {
            return "为独立 Team Mode 会话收敛目标与约束"
        }
        return "围绕 \(sourceTitle) 组织 Team Mode 协作"
    }

    private static func defaultContextSummary(sourceTitle: String, preview: String?) -> String {
        guard let sourceTitle = sourceTitle.trimmedNonEmpty else {
            return "独立 Team Mode 会话，等待补充上下文摘要。"
        }

        guard let preview else {
            return "来源会话：\(sourceTitle)。请补充本次 team 任务的上下文摘要。"
        }

        return "来源会话：\(sourceTitle)。最近上下文：\(preview)"
    }

    private static func normalizeLines(from text: String) -> [String] {
        text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
