import Foundation

struct StructuredFileDiff: Sendable, Equatable {
    let relativePath: String
    let absolutePath: String
    let kind: ProposedFileChangeKind
    let summary: DiffSummary
    let hunks: [DiffHunk]
    let renderPolicy: DiffRenderPolicy
}

struct DiffSummary: Sendable, Equatable {
    let additions: Int
    let deletions: Int
    let unchangedPrefixLines: Int
    let unchangedSuffixLines: Int
}

struct DiffHunk: Sendable, Equatable, Identifiable {
    let id: String
    let oldStart: Int
    let oldCount: Int
    let newStart: Int
    let newCount: Int
    let lines: [DiffHunkLine]
}

enum DiffHunkLine: Sendable, Equatable {
    case context(oldLine: Int, newLine: Int, text: String)
    case deletion(oldLine: Int, text: String)
    case addition(newLine: Int, text: String)
    case noNewlineMarker
}

enum DiffRenderPolicy: Sendable, Equatable {
    case unified
    case rewrite
    case binary
    case tooLargeCollapsed
}