import Foundation

enum GitStatusParser {
    enum ParseError: Error, Equatable {
        case invalidStatusOutput
        case invalidStatusLine(String)
    }

    static func parseStatus(_ output: String, repositoryRoot: URL) throws -> GitRepositorySnapshot {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ParseError.invalidStatusOutput }

        let lines = trimmed.split(whereSeparator: \ .isNewline).map(String.init)
        guard let branchLine = lines.first, branchLine.hasPrefix("## ") else {
            throw ParseError.invalidStatusOutput
        }

        let branchSummary = String(branchLine.dropFirst(3))
        let branchName = parseBranchName(branchSummary)
        let hasRemoteTrackingBranch = branchSummary.contains("...")
        let aheadCount = parseCounter(named: "ahead", in: branchSummary)
        let behindCount = parseCounter(named: "behind", in: branchSummary)

        var stagedChanges: [GitFileChange] = []
        var unstagedChanges: [GitFileChange] = []
        var untrackedChanges: [GitFileChange] = []

        for line in lines.dropFirst() where !line.isEmpty {
            if line.hasPrefix("??") {
                let rawPath = String(line.dropFirst(3))
                let path = rawPath.trimmingCharacters(in: .whitespaces)
                let change = GitFileChange(
                    relativePath: path,
                    absoluteURL: repositoryRoot.appending(path: path),
                    status: .untracked,
                    section: .untracked
                )
                untrackedChanges.append(change)
                continue
            }

            guard line.count >= 4 else { throw ParseError.invalidStatusLine(line) }

            let statusChars = Array(line.prefix(2))
            let rawPath = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            let normalizedPath = normalizePath(rawPath)

            if let stagedStatus = mapStatusCharacter(statusChars[0]) {
                stagedChanges.append(
                    GitFileChange(
                        relativePath: normalizedPath,
                        absoluteURL: repositoryRoot.appending(path: normalizedPath),
                        status: stagedStatus,
                        section: .staged
                    )
                )
            }

            if let unstagedStatus = mapStatusCharacter(statusChars[1]) {
                unstagedChanges.append(
                    GitFileChange(
                        relativePath: normalizedPath,
                        absoluteURL: repositoryRoot.appending(path: normalizedPath),
                        status: unstagedStatus,
                        section: .modified
                    )
                )
            }
        }

        return GitRepositorySnapshot(
            repositoryRoot: repositoryRoot,
            repositoryName: repositoryRoot.lastPathComponent,
            branchName: branchName,
            hasRemoteTrackingBranch: hasRemoteTrackingBranch,
            aheadCount: aheadCount,
            behindCount: behindCount,
            stagedChanges: stagedChanges,
            unstagedChanges: unstagedChanges,
            untrackedChanges: untrackedChanges
        )
    }

    private static func parseBranchName(_ branchSummary: String) -> String {
        let core = branchSummary.split(separator: "[", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? branchSummary
        let prefix = core.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? core
        return prefix.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parseCounter(named name: String, in summary: String) -> Int {
        let pattern = #"\b"# + name + #"\s+(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return 0 }
        let range = NSRange(summary.startIndex..., in: summary)
        guard let match = regex.firstMatch(in: summary, range: range),
              let captureRange = Range(match.range(at: 1), in: summary) else {
            return 0
        }
        return Int(summary[captureRange]) ?? 0
    }

    private static func normalizePath(_ rawPath: String) -> String {
        if let range = rawPath.range(of: " -> ") {
            return String(rawPath[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        return rawPath
    }

    private static func mapStatusCharacter(_ character: Character) -> GitChangeStatus? {
        switch character {
        case "A":
            return .added
        case "M":
            return .modified
        case "D":
            return .deleted
        case "R":
            return .renamed
        case "?":
            return .untracked
        case " ", ".":
            return nil
        default:
            return .modified
        }
    }
}