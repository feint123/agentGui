import Foundation

/// 从 `MemoryRecord` 推导稳定的、文件系统安全的 `.md` 文件名。
///
/// 规则：`<slug>_<id8>.md`
/// - slug = lowercase(title)，将 `[^a-z0-9]+` 替换为 `_`，截断至 40 字符，去除首尾 `_`
/// - id8 = record.id 前 8 个字符（若 id 不足 8 位则使用完整 id）
/// - 若 slug 为空（如纯 Unicode 标题），fallback 为 `memory_<id8>.md`
///
/// nonisolated enum，无副作用，可在任意并发上下文调用。
enum MemoryTopicFilename {

    static func filename(for record: MemoryRecord) -> String {
        let slug = sanitizeTitle(record.title)
        let id8 = String(record.id.prefix(8))
        if slug.isEmpty {
            return "memory_\(id8).md"
        }
        return "\(slug)_\(id8).md"
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
