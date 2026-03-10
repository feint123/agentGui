import Foundation

struct MemoryRetrievalPlanner {
    func makePlan(request: MemoryRuntimeRequest, profiles: [MemoryDomainProfile]) -> MemoryRetrievalPlan {
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
}