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
                let path = normalizePath(rawPath)
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
        let trimmed = rawPath.trimmingCharacters(in: .whitespaces)
        if let rename = splitRenamePath(trimmed) {
            return rename.newPath
        }
        return unquoteGitPath(trimmed)
    }

    private static func splitRenamePath(_ rawPath: String) -> (oldPath: String, newPath: String)? {
        if !rawPath.hasPrefix("\"") {
            guard let range = rawPath.range(of: " -> ") else {
                return nil
            }
            let oldPath = String(rawPath[..<range.lowerBound])
            let newPath = String(rawPath[range.upperBound...])
            return (oldPath: unquoteGitPath(oldPath), newPath: unquoteGitPath(newPath))
        }

        var index = rawPath.startIndex
        guard let oldPath = parsePathComponent(in: rawPath, startingAt: &index) else {
            return nil
        }

        skipSpaces(in: rawPath, index: &index)
        guard rawPath[index...].hasPrefix("->") else {
            return nil
        }
        index = rawPath.index(index, offsetBy: 2)
        skipSpaces(in: rawPath, index: &index)

        guard let newPath = parsePathComponent(in: rawPath, startingAt: &index) else {
            return nil
        }

        return (oldPath: unquoteGitPath(oldPath), newPath: unquoteGitPath(newPath))
    }

    private static func parsePathComponent(in rawPath: String, startingAt index: inout String.Index) -> String? {
        guard index < rawPath.endIndex else { return nil }

        if rawPath[index] == "\"" {
            index = rawPath.index(after: index)
            var result = ""

            while index < rawPath.endIndex {
                let character = rawPath[index]
                if character == "\\" {
                    let nextIndex = rawPath.index(after: index)
                    guard nextIndex < rawPath.endIndex else { break }
                    result.append(character)
                    result.append(rawPath[nextIndex])
                    index = rawPath.index(after: nextIndex)
                    continue
                }

                if character == "\"" {
                    index = rawPath.index(after: index)
                    return result
                }

                result.append(character)
                index = rawPath.index(after: index)
            }

            return result
        }

        let value = String(rawPath[index...]).trimmingCharacters(in: .whitespaces)
        index = rawPath.endIndex
        return value
    }

    private static func skipSpaces(in rawPath: String, index: inout String.Index) {
        while index < rawPath.endIndex, rawPath[index].isWhitespace {
            index = rawPath.index(after: index)
        }
    }

    private static func unquoteGitPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        let content: String

        if trimmed.first == "\"", trimmed.last == "\"", trimmed.count >= 2 {
            content = String(trimmed.dropFirst().dropLast())
        } else {
            content = trimmed
        }

        var bytes: [UInt8] = []
        var index = content.startIndex

        while index < content.endIndex {
            let character = content[index]
            if character == "\\" {
                let nextIndex = content.index(after: index)
                guard nextIndex < content.endIndex else {
                    bytes.append(UInt8(ascii: "\\"))
                    break
                }

                let nextCharacter = content[nextIndex]
                if let octalValue = decodeOctalEscape(in: content, from: nextIndex) {
                    bytes.append(octalValue.value)
                    index = octalValue.nextIndex
                    continue
                }

                switch nextCharacter {
                case "\\": bytes.append(UInt8(ascii: "\\"))
                case "\"": bytes.append(UInt8(ascii: "\""))
                case "n": bytes.append(UInt8(ascii: "\n"))
                case "t": bytes.append(UInt8(ascii: "\t"))
                default:
                    bytes.append(contentsOf: String(nextCharacter).utf8)
                }
                index = content.index(after: nextIndex)
                continue
            }

            bytes.append(contentsOf: String(character).utf8)
            index = content.index(after: index)
        }

        return String(decoding: bytes, as: UTF8.self)
    }

    private static func decodeOctalEscape(in content: String, from firstDigitIndex: String.Index) -> (value: UInt8, nextIndex: String.Index)? {
        var digits = ""
        var currentIndex = firstDigitIndex

        for _ in 0..<3 {
            guard currentIndex < content.endIndex else { return nil }
            let character = content[currentIndex]
            guard character >= "0", character <= "7" else { return nil }
            digits.append(character)
            currentIndex = content.index(after: currentIndex)
        }

        guard let value = UInt8(digits, radix: 8) else { return nil }
        return (value, currentIndex)
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