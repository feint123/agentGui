import Foundation

/// YAML frontmatter 中解析出的记忆话题文件头部信息。
/// 对齐 Claude Code `memoryScan.ts` 的 `MemoryHeader`。
struct MemoryTopicHeader: Sendable, Equatable {
    var filename: String        // 相对文件名，例如 "my_title_abc12345.md"
    var filePath: URL           // 绝对路径
    var mtimeMs: Double         // 文件修改时间（毫秒），用于排序和 freshness
    var title: String?          // frontmatter `name:` 字段
    var description: String?    // frontmatter `description:` 字段
    var memoryType: MemoryTopicType?   // frontmatter `type:` 字段（类型安全枚举）
}

/// 扫描 `memoryDir` 下的 `.md` 话题文件并解析 frontmatter。
///
/// - 排除 `MEMORY.md`（索引文件，由 bootstrap 注入，不参与 recall 选择）
/// - 返回全部记录（按 mtime 降序），200 行截断由 `MemoryIndexWriter.truncate()` 统一负责
/// - 每个文件只读前 `maxFrontmatterLines` 行，避免读取完整大文件
///
/// nonisolated struct，内部使用 async file I/O，可在任意并发上下文调用。
struct MemoryTopicScanner: Sendable {

    private static let maxFrontmatterLines = 30

    func scan(memoryDir: URL) async throws -> [MemoryTopicHeader] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: memoryDir.path) else { return [] }

        let entries: [URL]
        do {
            entries = try fm.contentsOfDirectory(
                at: memoryDir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            return []
        }

        let mdFiles = entries.filter {
            $0.pathExtension == "md" && $0.lastPathComponent != "MEMORY.md"
        }
        guard !mdFiles.isEmpty else { return [] }

        // 并发读取 frontmatter（最多读 maxFrontmatterLines 行）
        let headers: [MemoryTopicHeader?] = await withTaskGroup(of: MemoryTopicHeader?.self) { group in
            for fileURL in mdFiles {
                group.addTask {
                    await Self.readHeader(from: fileURL)
                }
            }
            var result: [MemoryTopicHeader?] = []
            for await header in group {
                result.append(header)
            }
            return result
        }

        return headers
            .compactMap { $0 }
            .sorted { $0.mtimeMs > $1.mtimeMs }
    }

    // MARK: - Private

    private static func readHeader(from url: URL) async -> MemoryTopicHeader? {
        let fm = FileManager.default
        let attrs = try? fm.attributesOfItem(atPath: url.path)
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let mtimeMs = mtime * 1000

        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let lines = content
            .components(separatedBy: "\n")
            .prefix(maxFrontmatterLines)
        let partial = lines.joined(separator: "\n")
        let fm2 = parseFrontmatter(partial)

        return MemoryTopicHeader(
            filename: url.lastPathComponent,
            filePath: url,
            mtimeMs: mtimeMs,
            title: fm2["name"],
            description: fm2["description"],
            memoryType: MemoryTopicType.parse(fm2["type"])
        )
    }

    /// 极简 YAML frontmatter 解析器：仅提取 `---` fenced 块内的 `key: "value"` 或 `key: value` 行。
    /// 不依赖外部 YAML 库，满足此处只读 name/description/type 的需求。
    private static func parseFrontmatter(_ text: String) -> [String: String] {
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return [:] }

        var result: [String: String] = [:]
        var inFrontmatter = false
        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if i == 0 && trimmed == "---" {
                inFrontmatter = true
                continue
            }
            if inFrontmatter && trimmed == "---" { break }
            if !inFrontmatter { continue }

            // `key: "value with spaces"` 或 `key: plain`
            guard let colonIdx = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[trimmed.startIndex..<colonIdx])
                .trimmingCharacters(in: .whitespaces)
            var value = String(trimmed[trimmed.index(after: colonIdx)...])
                .trimmingCharacters(in: .whitespaces)
            // 去掉引号
            if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
                value = String(value.dropFirst().dropLast())
                    .replacingOccurrences(of: "\\\"", with: "\"")
                    .replacingOccurrences(of: "\\\\", with: "\\")
            }
            result[key] = value
        }
        return result
    }
}
