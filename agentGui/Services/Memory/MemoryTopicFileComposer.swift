import Foundation

/// 将 `MemoryRecord` 渲染成带 YAML frontmatter 的 `.md` 话题文件内容。
///
/// 对齐 Claude Code `MEMORY_FRONTMATTER_EXAMPLE`。
/// nonisolated struct，无副作用，可在任意并发上下文调用。
struct MemoryTopicFileComposer: Sendable {

    private static let dateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    func compose(record: MemoryRecord) -> String {
        let created = Self.dateFormatter.string(from: record.createdAt)
        let updated = Self.dateFormatter.string(from: record.updatedAt)
        let body = bodyText(from: record)

        return """
        ---
        name: \(yamlQuote(record.title))
        description: \(yamlQuote(record.summary))
        type: \(record.kind.rawValue)
        id: \(record.id)
        scope: \(record.scope.namespace)
        created: \(created)
        updated: \(updated)
        ---

        \(body)
        """
    }

    // MARK: - Private

    private func bodyText(from record: MemoryRecord) -> String {
        switch record.payload {
        case .text(let text):
            return text
        case .structured(let dict):
            return dict.sorted { $0.key < $1.key }
                .map { "- **\($0.key)**: \($0.value)" }
                .joined(separator: "\n")
        }
    }

    /// 对 YAML 字符串值进行双引号包裹并转义内部引号。
    private func yamlQuote(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
                           .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
