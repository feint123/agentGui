import Foundation

struct MemoryRetrievalPlanner {
    func makeRMSPlan(request: MemoryRuntimeRequest, profiles: [MemoryDomainProfile], epistemicState: EpistemicState) -> MemoryRetrievalPlan {
        let phaseHint: MemoryRetrievalPhase? =
            (!epistemicState.frontiers.isEmpty ||
             !epistemicState.counterexamples.isEmpty ||
             !epistemicState.verificationDebt.isEmpty)
            ? .frontierResolution
            : nil
        let intent = MemoryRetrievalIntentClassifier().classify(request: request, phaseHint: phaseHint, epistemicState: epistemicState)
        return makePlan(request: request, profiles: profiles, intent: intent, epistemicState: epistemicState)
    }

    func makePlan(request: MemoryRuntimeRequest, profiles: [MemoryDomainProfile]) -> MemoryRetrievalPlan {
        let defaultIntent = MemoryRetrievalIntentClassifier().classify(request: request)
        return makePlan(request: request, profiles: profiles, intent: defaultIntent, epistemicState: EpistemicState())
    }

    func makePlan(
        request: MemoryRuntimeRequest,
        profiles: [MemoryDomainProfile],
        intent: MemoryRetrievalIntent,
        epistemicState: EpistemicState = EpistemicState()
    ) -> MemoryRetrievalPlan {
        let orderedLayers: [MemoryLayer]
        let itemBudgetByLayer: [MemoryLayer: Int]
        let objectBudgetByType: [MemoryRetrievalObjectType: Int]
        let highImpactFrontierCount = epistemicState.frontiers.filter { $0.impactLevel == .high || $0.impactLevel == .critical }.count

        switch request.taskKind {
        case .creativeWriting:
            orderedLayers = [.working, .task, .semantic, .episodic, .proceduralArchive]
            itemBudgetByLayer = budgets(for: orderedLayers, weights: [.working: 3, .task: 3, .semantic: 4, .episodic: 2, .proceduralArchive: 1], contextBudget: request.contextBudget)
        case .coding:
            orderedLayers = intent.phase == .frontierResolution
                ? [.task, .working, .proceduralArchive, .semantic, .episodic]
                : [.working, .task, .semantic, .episodic, .proceduralArchive]
            itemBudgetByLayer = budgets(
                for: orderedLayers,
                weights: intent.phase == .frontierResolution
                    ? [.task: 4 + highImpactFrontierCount, .working: 3, .proceduralArchive: 3 + min(epistemicState.counterexamples.count, 2), .semantic: 2, .episodic: 1]
                    : [.working: 3, .task: 4, .semantic: 3, .episodic: 1, .proceduralArchive: 1],
                contextBudget: request.contextBudget
            )
        case .generalAssistant:
            orderedLayers = [.working, .semantic]
            itemBudgetByLayer = budgets(for: orderedLayers, weights: [.working: 2, .semantic: 3], contextBudget: request.contextBudget)
        }

        objectBudgetByType = objectBudgets(for: intent, contextBudget: request.contextBudget, epistemicState: epistemicState)

        return MemoryRetrievalPlan(
            orderedLayers: orderedLayers,
            itemBudgetByLayer: itemBudgetByLayer,
            objectBudgetByType: objectBudgetByType,
            profileIDs: profiles.map(\.id),
            includeArchived: false
        )
    }

    private func budgets(for layers: [MemoryLayer], weights: [MemoryLayer: Int], contextBudget: Int) -> [MemoryLayer: Int] {
        let normalizedBudget = max(contextBudget / 1000, layers.count)
        let totalWeight = max(weights.values.reduce(0, +), 1)
        var result: [MemoryLayer: Int] = [:]

        for layer in layers {
            let weight = weights[layer] ?? 1
            result[layer] = max((normalizedBudget * weight) / totalWeight, 1)
        }

        return result
    }

    private func objectBudgets(
        for intent: MemoryRetrievalIntent,
        contextBudget: Int,
        epistemicState: EpistemicState
    ) -> [MemoryRetrievalObjectType: Int] {
        let normalizedBudget = max(contextBudget / 2000, 2)
        var result: [MemoryRetrievalObjectType: Int] = [:]
        let extraHighRiskBudget = epistemicState.frontiers.filter { $0.impactLevel == .high || $0.impactLevel == .critical }.count

        for objectType in intent.neededObjectTypes {
            switch objectType {
            case .procedure where intent.phase == .verification || intent.phase == .recovery:
                result[objectType] = max(normalizedBudget + extraHighRiskBudget, 1)
            case .procedure where intent.phase == .frontierResolution:
                result[objectType] = max(normalizedBudget + max(epistemicState.counterexamples.count, 1), 1)
            case .counterexample:
                result[objectType] = max(normalizedBudget + extraHighRiskBudget, 2)
            case .constraint:
                result[objectType] = max(normalizedBudget + (epistemicState.activeConstraints.isEmpty ? 0 : 1), 1)
            case .verificationDebt:
                result[objectType] = max(normalizedBudget + epistemicState.verificationDebt.count, 1)
            case .fact:
                result[objectType] = max(normalizedBudget, 1)
            default:
                result[objectType] = 1
            }
        }
        return result
    }
}