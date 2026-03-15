import Foundation

struct MemoryEvidenceResolutionResult: Equatable, Sendable {
    var dereferenceCount: Int
    var summaries: [String]
}

struct MemoryEvidenceResolver {
    func resolve(for records: [MemoryRecord]) -> MemoryEvidenceResolutionResult {
        let anchors = records.flatMap(\.evidenceAnchors)
        return MemoryEvidenceResolutionResult(
            dereferenceCount: anchors.count,
            summaries: anchors.map { "\($0.kind.rawValue):\($0.identifier) \($0.summary)" }
        )
    }
}
