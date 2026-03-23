import Foundation

enum UnifiedDiffSerializer {
    static func serialize(_ diff: StructuredFileDiff) -> String {
        let header = fileHeader(for: diff)
        let body = diff.hunks.flatMap { hunk in
            serialize(hunk: hunk)
        }
        return (header + body).joined(separator: "\n")
    }

    private static func fileHeader(for diff: StructuredFileDiff) -> [String] {
        switch diff.kind {
        case .add:
            return ["--- /dev/null", "+++ b/\(diff.relativePath)"]
        case .delete:
            return ["--- a/\(diff.relativePath)", "+++ /dev/null"]
        case .modify, .rename:
            return ["--- a/\(diff.relativePath)", "+++ b/\(diff.relativePath)"]
        }
    }

    private static func serialize(hunk: DiffHunk) -> [String] {
        let header = "@@ -\(hunk.oldStart),\(hunk.oldCount) +\(hunk.newStart),\(hunk.newCount) @@"
        return [header] + hunk.lines.map { line in
            switch line {
            case .context(_, _, let text):
                return " \(text)"
            case .deletion(_, let text):
                return "-\(text)"
            case .addition(_, let text):
                return "+\(text)"
            case .noNewlineMarker:
                return "\\ No newline at end of file"
            }
        }
    }
}