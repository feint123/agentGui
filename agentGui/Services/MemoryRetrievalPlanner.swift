import Foundation

struct MemoryRetrievalPlanner {
    func makePlan(request: MemoryRuntimeRequest, profiles: [MemoryDomainProfile]) -> MemoryRetrievalPlan {
        let defaultIntent = MemoryRetrievalIntentClassifier().classify(request: request)
        return makePlan(request: request, profiles: profiles, intent: defaultIntent)
    }

    func makeLegacyPlan(request: MemoryRuntimeRequest, profiles: [MemoryDomainProfile]) -> MemoryRetrievalPlan {
        let orderedLayers: [MemoryLayer]
        let itemBudgetByLayer: [MemoryLayer: Int]

        switch request.taskKind {
        case .creativeWriting:
            orderedLayers = [.working, .task, .semantic, .episodic, .proceduralArchive]
            itemBudgetByLayer = budgets(for: orderedLayers, weights: [.working: 3, .task: 3, .semantic: 4, .episodic: 2, .proceduralArchive: 1], contextBudget: request.contextBudget)
        case .coding:
            orderedLayers = [.working, .task, .semantic, .episodic, .proceduralArchive]
            itemBudgetByLayer = budgets(for: orderedLayers, weights: [.working: 3, .task: 4, .semantic: 3, .episodic: 1, .proceduralArchive: 1], contextBudget: request.contextBudget)
        case .generalAssistant:
            orderedLayers = [.working, .semantic]
            itemBudgetByLayer = budgets(for: orderedLayers, weights: [.working: 2, .semantic: 3], contextBudget: request.contextBudget)
        }

        return MemoryRetrievalPlan(
            orderedLayers: orderedLayers,
            itemBudgetByLayer: itemBudgetByLayer,
            objectBudgetByType: [:],
            profileIDs: profiles.map(\.id),
            includeArchived: false
        )
    }

    func makePlan(request: MemoryRuntimeRequest, profiles: [MemoryDomainProfile], intent: MemoryRetrievalIntent) -> MemoryRetrievalPlan {
        let orderedLayers: [MemoryLayer]
        let itemBudgetByLayer: [MemoryLayer: Int]
        let objectBudgetByType: [MemoryRetrievalObjectType: Int]

        switch request.taskKind {
        case .creativeWriting:
            orderedLayers = [.working, .task, .semantic, .episodic, .proceduralArchive]
            itemBudgetByLayer = budgets(for: orderedLayers, weights: [.working: 3, .task: 3, .semantic: 4, .episodic: 2, .proceduralArchive: 1], contextBudget: request.contextBudget)
        case .coding:
            orderedLayers = [.working, .task, .semantic, .episodic, .proceduralArchive]
            itemBudgetByLayer = budgets(for: orderedLayers, weights: [.working: 3, .task: 4, .semantic: 3, .episodic: 1, .proceduralArchive: 1], contextBudget: request.contextBudget)
        case .generalAssistant:
            orderedLayers = [.working, .semantic]
            itemBudgetByLayer = budgets(for: orderedLayers, weights: [.working: 2, .semantic: 3], contextBudget: request.contextBudget)
        }

        objectBudgetByType = objectBudgets(for: intent, contextBudget: request.contextBudget)

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

    private func objectBudgets(for intent: MemoryRetrievalIntent, contextBudget: Int) -> [MemoryRetrievalObjectType: Int] {
        let normalizedBudget = max(contextBudget / 2000, 2)
        var result: [MemoryRetrievalObjectType: Int] = [:]
        for objectType in intent.neededObjectTypes {
            switch objectType {
            case .procedure where intent.phase == .verification || intent.phase == .recovery:
                result[objectType] = max(normalizedBudget, 1)
            case .fact:
                result[objectType] = max(normalizedBudget, 1)
            default:
                result[objectType] = 1
            }
        }
        return result
    }
}