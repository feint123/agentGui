import Foundation

struct MemoryConflictResolver {
    func detectConflicts(for candidate: MemoryCandidate, existingRecords: [MemoryRecord]) -> [MemoryConflict] {
        existingRecords.compactMap { existing in
            guard existing.scope == candidate.scope else { return nil }

            let sharedTags = Set(existing.tags).intersection(candidate.tags)
            let matchesTitle = existing.title == candidate.title
            if matchesTitle || !sharedTags.isEmpty {
                return MemoryConflict(
                    existingRecordID: existing.id,
                    candidateID: candidate.id,
                    reason: matchesTitle ? "matching-title" : "matching-tags"
                )
            }

            return nil
        }
    }
}