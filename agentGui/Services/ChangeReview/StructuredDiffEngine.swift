import Foundation

struct StructuredDiffEngine {
    func build(
        relativePath: String,
        absolutePath: String,
        kind: ProposedFileChangeKind,
        baseContent: String?,
        stagedContent: String?,
        contextLines: Int = 3,
        interHunkContext: Int = 0
    ) throws -> StructuredFileDiff {
        let oldText = LineTokenization.tokenize(baseContent)
        let newText = LineTokenization.tokenize(stagedContent)

        switch kind {
        case .add:
            return buildAddedFile(
                relativePath: relativePath,
                absolutePath: absolutePath,
                lines: newText.lines,
                hasTrailingNewline: newText.hasTrailingNewline
            )
        case .delete:
            return buildDeletedFile(
                relativePath: relativePath,
                absolutePath: absolutePath,
                lines: oldText.lines,
                hasTrailingNewline: oldText.hasTrailingNewline
            )
        case .modify, .rename:
            return buildModifiedFile(
                relativePath: relativePath,
                absolutePath: absolutePath,
                kind: kind,
                oldText: oldText,
                newText: newText,
                contextLines: contextLines,
                interHunkContext: interHunkContext
            )
        }
    }

    private func buildAddedFile(
        relativePath: String,
        absolutePath: String,
        lines: [String],
        hasTrailingNewline: Bool
    ) -> StructuredFileDiff {
        var hunkLines: [DiffHunkLine] = lines.enumerated().map { index, line in
            .addition(newLine: index + 1, text: line)
        }
        if !hasTrailingNewline, !lines.isEmpty {
            hunkLines.append(.noNewlineMarker)
        }

        let count = max(lines.count, lines.isEmpty ? 0 : lines.count)
        let hunk = DiffHunk(
            id: "hunk-0",
            oldStart: 0,
            oldCount: 0,
            newStart: lines.isEmpty ? 0 : 1,
            newCount: count,
            lines: hunkLines
        )

        return StructuredFileDiff(
            relativePath: relativePath,
            absolutePath: absolutePath,
            kind: .add,
            summary: .init(additions: lines.count, deletions: 0, unchangedPrefixLines: 0, unchangedSuffixLines: 0),
            hunks: lines.isEmpty ? [] : [hunk],
            renderPolicy: .unified
        )
    }

    private func buildDeletedFile(
        relativePath: String,
        absolutePath: String,
        lines: [String],
        hasTrailingNewline: Bool
    ) -> StructuredFileDiff {
        var hunkLines: [DiffHunkLine] = lines.enumerated().map { index, line in
            .deletion(oldLine: index + 1, text: line)
        }
        if !hasTrailingNewline, !lines.isEmpty {
            hunkLines.append(.noNewlineMarker)
        }

        let count = max(lines.count, lines.isEmpty ? 0 : lines.count)
        let hunk = DiffHunk(
            id: "hunk-0",
            oldStart: lines.isEmpty ? 0 : 1,
            oldCount: count,
            newStart: 0,
            newCount: 0,
            lines: hunkLines
        )

        return StructuredFileDiff(
            relativePath: relativePath,
            absolutePath: absolutePath,
            kind: .delete,
            summary: .init(additions: 0, deletions: lines.count, unchangedPrefixLines: 0, unchangedSuffixLines: 0),
            hunks: lines.isEmpty ? [] : [hunk],
            renderPolicy: .unified
        )
    }

    private func buildModifiedFile(
        relativePath: String,
        absolutePath: String,
        kind: ProposedFileChangeKind,
        oldText: TokenizedText,
        newText: TokenizedText,
        contextLines: Int,
        interHunkContext: Int
    ) -> StructuredFileDiff {
        let trimmed = trimCommonEdges(oldLines: oldText.lines, newLines: newText.lines)
        let operations = buildOperations(oldLines: trimmed.oldLines, newLines: trimmed.newLines)
        let hunks = buildHunks(
            oldLines: oldText.lines,
            newLines: newText.lines,
            trimmed: trimmed,
            operations: operations,
            contextLines: contextLines,
            interHunkContext: interHunkContext,
            needsNoNewlineMarker: oldText.hasTrailingNewline != newText.hasTrailingNewline
        )

        let additions = operations.reduce(into: 0) { count, operation in
            if case .insert = operation.kind {
                count += 1
            }
        }
        let deletions = operations.reduce(into: 0) { count, operation in
            if case .delete = operation.kind {
                count += 1
            }
        }

        return StructuredFileDiff(
            relativePath: relativePath,
            absolutePath: absolutePath,
            kind: kind,
            summary: .init(
                additions: additions,
                deletions: deletions,
                unchangedPrefixLines: trimmed.prefixCount,
                unchangedSuffixLines: trimmed.suffixCount
            ),
            hunks: hunks,
            renderPolicy: .unified
        )
    }

    private func trimCommonEdges(oldLines: [String], newLines: [String]) -> TrimmedDiffInput {
        var prefixCount = 0
        while prefixCount < oldLines.count,
              prefixCount < newLines.count,
              oldLines[prefixCount] == newLines[prefixCount] {
            prefixCount += 1
        }

        var suffixCount = 0
        while suffixCount < oldLines.count - prefixCount,
              suffixCount < newLines.count - prefixCount,
              oldLines[oldLines.count - 1 - suffixCount] == newLines[newLines.count - 1 - suffixCount] {
            suffixCount += 1
        }

        let oldEnd = max(prefixCount, oldLines.count - suffixCount)
        let newEnd = max(prefixCount, newLines.count - suffixCount)
        return TrimmedDiffInput(
            prefixCount: prefixCount,
            suffixCount: suffixCount,
            oldLines: Array(oldLines[prefixCount..<oldEnd]),
            newLines: Array(newLines[prefixCount..<newEnd])
        )
    }

    private func buildOperations(oldLines: [String], newLines: [String]) -> [EditOperation] {
        let lcs = longestCommonSubsequence(oldLines: oldLines, newLines: newLines)
        var operations: [EditOperation] = []
        var oldIndex = 0
        var newIndex = 0
        var matchCursor = 0

        while oldIndex < oldLines.count || newIndex < newLines.count {
            if matchCursor < lcs.count,
               oldIndex == lcs[matchCursor].oldIndex,
               newIndex == lcs[matchCursor].newIndex {
                operations.append(.init(kind: .equal, oldIndex: oldIndex, newIndex: newIndex))
                oldIndex += 1
                newIndex += 1
                matchCursor += 1
                continue
            }

            if matchCursor < lcs.count {
                if oldIndex < lcs[matchCursor].oldIndex {
                    operations.append(.init(kind: .delete, oldIndex: oldIndex, newIndex: nil))
                    oldIndex += 1
                    continue
                }
                if newIndex < lcs[matchCursor].newIndex {
                    operations.append(.init(kind: .insert, oldIndex: nil, newIndex: newIndex))
                    newIndex += 1
                    continue
                }
            }

            if oldIndex < oldLines.count {
                operations.append(.init(kind: .delete, oldIndex: oldIndex, newIndex: nil))
                oldIndex += 1
            }
            if newIndex < newLines.count {
                operations.append(.init(kind: .insert, oldIndex: nil, newIndex: newIndex))
                newIndex += 1
            }
        }

        return operations
    }

    private func longestCommonSubsequence(oldLines: [String], newLines: [String]) -> [MatchPair] {
        guard !oldLines.isEmpty, !newLines.isEmpty else {
            return []
        }

        let oldCount = oldLines.count
        let newCount = newLines.count
        var matrix = Array(
            repeating: Array(repeating: 0, count: newCount + 1),
            count: oldCount + 1
        )

        for oldIndex in 0..<oldCount {
            for newIndex in 0..<newCount {
                if oldLines[oldIndex] == newLines[newIndex] {
                    matrix[oldIndex + 1][newIndex + 1] = matrix[oldIndex][newIndex] + 1
                } else {
                    matrix[oldIndex + 1][newIndex + 1] = max(matrix[oldIndex][newIndex + 1], matrix[oldIndex + 1][newIndex])
                }
            }
        }

        var matches: [MatchPair] = []
        var oldIndex = oldCount
        var newIndex = newCount
        while oldIndex > 0, newIndex > 0 {
            if oldLines[oldIndex - 1] == newLines[newIndex - 1] {
                matches.append(.init(oldIndex: oldIndex - 1, newIndex: newIndex - 1))
                oldIndex -= 1
                newIndex -= 1
            } else if matrix[oldIndex - 1][newIndex] >= matrix[oldIndex][newIndex - 1] {
                oldIndex -= 1
            } else {
                newIndex -= 1
            }
        }

        return matches.reversed()
    }

    private func buildHunks(
        oldLines: [String],
        newLines: [String],
        trimmed: TrimmedDiffInput,
        operations: [EditOperation],
        contextLines: Int,
        interHunkContext: Int,
        needsNoNewlineMarker: Bool
    ) -> [DiffHunk] {
        let opRecords = materializeOperationRecords(
            oldLines: trimmed.oldLines,
            newLines: trimmed.newLines,
            operations: operations,
            oldBaseLine: trimmed.prefixCount + 1,
            newBaseLine: trimmed.prefixCount + 1
        )

        let prefixRecords = buildContextRecords(
            oldLines: oldLines,
            newLines: newLines,
            oldRange: 0..<trimmed.prefixCount,
            newRange: 0..<trimmed.prefixCount
        )
        let suffixRecords = buildContextRecords(
            oldLines: oldLines,
            newLines: newLines,
            oldRange: (oldLines.count - trimmed.suffixCount)..<oldLines.count,
            newRange: (newLines.count - trimmed.suffixCount)..<newLines.count
        )
        let allRecords = prefixRecords + opRecords + suffixRecords

        let changeIndices = allRecords.indices.filter { index in
            switch allRecords[index] {
            case .context:
                return false
            case .deletion, .addition:
                return true
            case .noNewlineMarker:
                return false
            }
        }

        guard !changeIndices.isEmpty else {
            return []
        }

        let groups = groupChangeIndices(changeIndices, records: allRecords, contextLines: contextLines, interHunkContext: interHunkContext)
        return groups.enumerated().map { offset, range in
            var lines = Array(allRecords[range])
            if needsNoNewlineMarker, offset == groups.count - 1 {
                lines.append(.noNewlineMarker)
            }
            return buildHunk(id: "hunk-\(offset)", lines: lines)
        }
    }

    private func buildContextRecords(
        oldLines: [String],
        newLines: [String],
        oldRange: Range<Int>,
        newRange: Range<Int>
    ) -> [DiffHunkLine] {
        guard oldRange.count == newRange.count else {
            return []
        }

        return zip(oldRange, newRange).map { oldIndex, newIndex in
            .context(
                oldLine: oldIndex + 1,
                newLine: newIndex + 1,
                text: oldLines[oldIndex]
            )
        }
    }

    private func materializeOperationRecords(
        oldLines: [String],
        newLines: [String],
        operations: [EditOperation],
        oldBaseLine: Int,
        newBaseLine: Int
    ) -> [DiffHunkLine] {
        var records: [DiffHunkLine] = []
        for operation in operations {
            switch operation.kind {
            case .equal:
                guard let oldIndex = operation.oldIndex, let newIndex = operation.newIndex else { continue }
                records.append(.context(
                    oldLine: oldBaseLine + oldIndex,
                    newLine: newBaseLine + newIndex,
                    text: oldLines[oldIndex]
                ))
            case .delete:
                guard let oldIndex = operation.oldIndex else { continue }
                records.append(.deletion(
                    oldLine: oldBaseLine + oldIndex,
                    text: oldLines[oldIndex]
                ))
            case .insert:
                guard let newIndex = operation.newIndex else { continue }
                records.append(.addition(
                    newLine: newBaseLine + newIndex,
                    text: newLines[newIndex]
                ))
            }
        }
        return records
    }

    private func groupChangeIndices(
        _ changeIndices: [Int],
        records: [DiffHunkLine],
        contextLines: Int,
        interHunkContext: Int
    ) -> [ClosedRange<Int>] {
        guard let first = changeIndices.first else {
            return []
        }

        var groups: [ClosedRange<Int>] = []
        var currentStart = max(0, first - contextLines)
        var currentEnd = min(records.count - 1, first + contextLines)

        for index in changeIndices.dropFirst() {
            let proposedStart = max(0, index - contextLines)
            let proposedEnd = min(records.count - 1, index + contextLines)
            if proposedStart <= currentEnd + interHunkContext + 1 {
                currentEnd = max(currentEnd, proposedEnd)
            } else {
                groups.append(currentStart...currentEnd)
                currentStart = proposedStart
                currentEnd = proposedEnd
            }
        }

        groups.append(currentStart...currentEnd)
        return groups
    }

    private func buildHunk(id: String, lines: [DiffHunkLine]) -> DiffHunk {
        let oldNumbers = lines.compactMap { line -> Int? in
            switch line {
            case .context(let oldLine, _, _):
                return oldLine
            case .deletion(let oldLine, _):
                return oldLine
            case .addition, .noNewlineMarker:
                return nil
            }
        }
        let newNumbers = lines.compactMap { line -> Int? in
            switch line {
            case .context(_, let newLine, _):
                return newLine
            case .addition(let newLine, _):
                return newLine
            case .deletion, .noNewlineMarker:
                return nil
            }
        }

        let oldStart = oldNumbers.first ?? 0
        let newStart = newNumbers.first ?? 0
        let oldCount = oldNumbers.count
        let newCount = newNumbers.count

        return DiffHunk(
            id: id,
            oldStart: oldStart,
            oldCount: oldCount,
            newStart: newStart,
            newCount: newCount,
            lines: lines
        )
    }
}

private struct TrimmedDiffInput {
    let prefixCount: Int
    let suffixCount: Int
    let oldLines: [String]
    let newLines: [String]
}

private struct MatchPair {
    let oldIndex: Int
    let newIndex: Int
}

private struct EditOperation {
    enum Kind {
        case equal
        case delete
        case insert
    }

    let kind: Kind
    let oldIndex: Int?
    let newIndex: Int?
}