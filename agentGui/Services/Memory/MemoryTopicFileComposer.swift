import Foundation

/// 话题文件内容组合器。
///
/// `compose(record: MemoryRecord)` 已在 M-02 移除。
/// M-04 将新增 `compose(title:description:type:content:now:)` 方法。
/// nonisolated struct，无副作用，可在任意并发上下文调用。
struct MemoryTopicFileComposer: Sendable {

    private static let dateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// 对 YAML 字符串值进行双引号包裹并转义内部引号。
    static func yamlQuote(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
                           .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
