import Foundation

struct MemoryBridgeExpansionResult: Equatable, Sendable {
    var edges: [MemoryBridgeEdge]
    var additionalRecords: [MemoryRecord]
}

struct MemoryBridgeExpander {
    // Keep bridge expansion shallow so prompt growth stays bounded and predictable.
    func expand(selectedRecords: [MemoryRecord], candidateRecords: [MemoryRecord]) -> MemoryBridgeExpansionResult {
        var edges: [MemoryBridgeEdge] = []
        var additional: [MemoryRecord] = []

        for selected in selectedRecords {
            guard selected.tags.contains("failed-attempt") || selected.title.localizedCaseInsensitiveContains("failure") else {
                continue
            }

            for candidate in candidateRecords where candidate.id != selected.id {
                let isRecoveryCandidate = candidate.tags.contains("recovery-tip") ||
                    candidate.tags.contains("tactic-kernel") ||
                    candidate.tags.contains("counterexample") ||
                    candidate.tags.contains("procedure") ||
                    candidate.title.localizedCaseInsensitiveContains("scheme")
                guard isRecoveryCandidate else { continue }

                edges.append(
                    MemoryBridgeEdge(
                        sourceRecordID: selected.id,
                        targetRecordID: candidate.id,
                        relationship: "recovery-path"
                    )
                )
                additional.append(candidate)
            }
        }

        return MemoryBridgeExpansionResult(edges: edges, additionalRecords: deduplicated(additional))
    }

    private func deduplicated(_ records: [MemoryRecord]) -> [MemoryRecord] {
        var seen: Set<String> = []
        return records.filter { seen.insert($0.id).inserted }
    }
}