import Foundation

enum GitLogParser {

    static let commitSeparator = "---COMMIT---"
    static let endMarker = "---END---"

    /// `git log --format=---COMMIT---%n%H%n%s%n%B%n---END---` 输出的解析
    static func parse(_ output: String) throws -> [GitCommit] {
        guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }

        let blocks = output.components(separatedBy: commitSeparator)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return blocks.compactMap { block -> GitCommit? in
            // 去掉末尾的 ---END---
            let cleaned = block
                .components(separatedBy: endMarker).first?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? block

            let lines = cleaned.components(separatedBy: "\n")
            guard lines.count >= 2 else { return nil }

            let sha = lines[0].trimmingCharacters(in: .whitespaces)
            guard sha.count >= 7 else { return nil }

            let summary = lines[1].trimmingCharacters(in: .whitespaces)
            let bodyLines = lines.dropFirst(2)
            let fullMessage = ([summary] + bodyLines)
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            return GitCommit(
                sha: sha,
                message: summary,
                fullMessage: fullMessage,
                author: "",
                authorEmail: "",
                date: Date()
            )
        }
    }
}

// MARK: - Rich format (author + date)

extension GitLogParser {
    /// 解析包含 author / date 的富格式输出
    /// 格式：---COMMIT---%n%H%n%s%n%an%n%ae%n%aI%n%B%n---END---
    static func parseRich(_ output: String) throws -> [GitCommit] {
        guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }

        let iso8601 = ISO8601DateFormatter()

        let blocks = output.components(separatedBy: commitSeparator)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return blocks.compactMap { block -> GitCommit? in
            let cleaned = block
                .components(separatedBy: endMarker).first?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? block

            let lines = cleaned.components(separatedBy: "\n")
            guard lines.count >= 5 else { return nil }

            let sha         = lines[0].trimmingCharacters(in: .whitespaces)
            let summary     = lines[1].trimmingCharacters(in: .whitespaces)
            let author      = lines[2].trimmingCharacters(in: .whitespaces)
            let authorEmail = lines[3].trimmingCharacters(in: .whitespaces)
            let dateString  = lines[4].trimmingCharacters(in: .whitespaces)
            let bodyLines   = lines.dropFirst(5)
            let fullMessage = ([summary] + bodyLines)
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard sha.count >= 7 else { return nil }
            let date = iso8601.date(from: dateString) ?? Date()

            return GitCommit(
                sha: sha,
                message: summary,
                fullMessage: fullMessage,
                author: author,
                authorEmail: authorEmail,
                date: date
            )
        }
    }
}
