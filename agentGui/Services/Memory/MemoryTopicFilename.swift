import Foundation

/// 文件系统安全的 `.md` 话题文件名工具。
///
/// 规则：`<slug>_<id8>.md`
/// - slug = lowercase(title)，将 `[^a-z0-9]+` 替换为 `_`，截断至 40 字符，去除首尾 `_`
/// - id8 = id 前 8 个字符（若 id 不足 8 位则使用完整 id）
/// - 若 slug 为空（如纽 Unicode 标题），fallback 为 `memory_<id8>.md`
///
/// `filename(for record: MemoryRecord)` 已在 M-02 移除；使用 `filename(title:id:)` 替代。
/// nonisolated enum，无副作用，可在任意并发上下文调用。
enum MemoryTopicFilename {

    static func filename(title: String, id: String) -> String {
        let slug = sanitizeTitle(title)
        let id8 = String(id.prefix(8))
        if slug.isEmpty {
            return "memory_\(id8).md"
        }
        return "\(slug)_\(id8).md"
    }

    /// 从纯文本 `title` + 外部提供的 `suffix` 生成文件名。
    /// 用于 `memory_write` 工具直接写文件时，无需构造 `MemoryRecord`。
    ///
    /// - Parameters:
    ///   - title: 记忆标题（来自工具输入），可为任意 Unicode 字符串
    ///   - suffix: 调用方提供的唯一后缀（如 UUID prefix 8 位）
    static func filename(title: String, suffix: String) -> String {
        let slug = sanitizeTitle(title)
        if slug.isEmpty {
            return "memory_\(suffix).md"
        }
        return "\(slug)_\(suffix).md"
    }

    /// ASCII 化并 slug 化标题，截断至 40 字符。
    /// 安全保证：结果中不含 `/`、`..`、空字节。
    static func sanitizeTitle(_ title: String) -> String {
        guard !title.isEmpty else { return "" }

        // 小写化，仅保留 a-z 0-9，其余替换为 _
        let lowered = title.lowercased()
        var slug = lowered.unicodeScalars.map { scalar -> Character in
            let v = scalar.value
            if (v >= UInt32(("a" as UnicodeScalar).value) && v <= UInt32(("z" as UnicodeScalar).value))
                || (v >= UInt32(("0" as UnicodeScalar).value) && v <= UInt32(("9" as UnicodeScalar).value)) {
                return Character(scalar)
            }
            return "_"
        }.map(String.init).joined()

        // 合并多个连续 _ 为一个
        while slug.contains("__") {
            slug = slug.replacingOccurrences(of: "__", with: "_")
        }
        // 去除首尾 _
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        // 截断至 40 字符
        if slug.count > 40 {
            slug = String(slug.prefix(40)).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        }
        return slug
    }
}
