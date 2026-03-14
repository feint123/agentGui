import Foundation
import Observation

@MainActor
@Observable
final class MemoryRuntimeSnapshotViewModel {
    enum Dimension: String, CaseIterable {
        case layer
        case kind
        case scope
        case verificationStatus
        case source

        var metricDimension: MemoryRuntimeSnapshotMetricDimension {
            switch self {
            case .layer:
                return .layer
            case .kind:
                return .kind
            case .scope:
                return .scope
            case .verificationStatus:
                return .verificationStatus
            case .source:
                return .source
            }
        }
    }

    enum Metric: String, CaseIterable {
        case count
        case estimatedChars
    }

    struct ChartItem: Identifiable, Equatable {
        var id: String { label }
        var label: String
        var value: Int
    }

    struct SelectedSummary: Equatable {
        var candidateCount: Int
        var selectedCount: Int
        var excludedCount: Int
        var totalEstimatedPromptChars: Int
    }

    struct LayerBudgetItem: Identifiable, Equatable {
        var id: String { layer.rawValue }
        var layer: MemoryLayer
        var budget: Int
        var candidates: Int
        var selected: Int
    }

    let snapshot: MemoryRuntimeSnapshot
    var dimension: Dimension = .layer
    var metric: Metric = .count

    init(snapshot: MemoryRuntimeSnapshot) {
        self.snapshot = snapshot
    }

    var chartItems: [ChartItem] {
        let source = switch metric {
        case .count:
            snapshot.metrics.countBreakdowns[dimension.metricDimension] ?? [:]
        case .estimatedChars:
            snapshot.metrics.estimatedCharBreakdowns[dimension.metricDimension] ?? [:]
        }

        return source
            .map { ChartItem(label: $0.key, value: $0.value) }
            .sorted { lhs, rhs in
                if lhs.value == rhs.value {
                    return lhs.label < rhs.label
                }
                return lhs.value > rhs.value
            }
    }

    var selectedSummary: SelectedSummary {
        SelectedSummary(
            candidateCount: snapshot.metrics.candidateCount,
            selectedCount: snapshot.metrics.selectedCount,
            excludedCount: snapshot.metrics.excludedCount,
            totalEstimatedPromptChars: snapshot.metrics.totalEstimatedPromptChars
        )
    }

    var selectedRecords: [MemoryRuntimeSnapshotRecord] {
        snapshot.selectedRecords.sorted { lhs, rhs in
            switch (lhs.promptOrder, rhs.promptOrder) {
            case let (left?, right?):
                return left < right
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                return lhs.title < rhs.title
            }
        }
    }

    var excludedRecords: [MemoryRuntimeSnapshotRecord] {
        snapshot.excludedRecords.sorted { lhs, rhs in
            if lhs.layer == rhs.layer {
                return lhs.title < rhs.title
            }
            return lhs.layer.rawValue < rhs.layer.rawValue
        }
    }

    var layerBudgetItems: [LayerBudgetItem] {
        snapshot.plan.orderedLayers.map { layer in
            LayerBudgetItem(
                layer: layer,
                budget: snapshot.plan.itemBudgetByLayer[layer] ?? 0,
                candidates: snapshot.plan.candidateCountByLayer[layer] ?? 0,
                selected: snapshot.plan.selectedCountByLayer[layer] ?? 0
            )
        }
    }

    var bridgeExpansionCount: Int {
        snapshot.bridgeExpansions.count
    }

    var dereferenceCount: Int {
        snapshot.dereferenceCount
    }

    var workingSetCost: Int {
        snapshot.metrics.workingSetCost
    }

    var retrievalIntentSummary: String {
        guard let intent = snapshot.plan.retrievalIntent else {
            return "Legacy layer-based retrieval"
        }

        let objectTypes = intent.neededObjectTypes
            .map(\.rawValue)
            .sorted()
            .joined(separator: ", ")
        if objectTypes.isEmpty {
            return "\(intent.phase.rawValue)"
        }
        return "\(intent.phase.rawValue) · \(objectTypes)"
    }
}