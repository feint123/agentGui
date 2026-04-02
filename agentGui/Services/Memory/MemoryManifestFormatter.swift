import Foundation

/// 将 `[MemoryTopicHeader]` 格式化为 side query prompt 使用的 manifest 文本。
///
/// 每行格式（对齐 Claude Code `formatMemoryManifest`）：
/// ```
/// - [type] filename (ISO8601): description
/// - filename (ISO8601): description      ← type 为 nil 时省略 [type]
/// - filename (ISO8601)                    ← description 为 nil 时省略描述
/// ```
struct MemoryManifestFormatter: Sendable {

    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    func format(_ headers: [MemoryTopicHeader]) -> String {
        guard !headers.isEmpty else { return "" }
        return headers.map { line(for: $0) }.joined(separator: "\n")
    }

    // MARK: - Private

    private func line(for header: MemoryTopicHeader) -> String {
        let typeTag = header.memoryType.map { "[\($0)] " } ?? ""
        let date = Self.iso8601.string(
            from: Date(timeIntervalSince1970: header.mtimeMs / 1000)
        )
        let descPart = header.description.map { ": \($0)" } ?? ""
        return "- \(typeTag)\(header.filename) (\(date))\(descPart)"
    }
}
