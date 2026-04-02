import Foundation

extension RMSInsight {

    /// 将 RMSInsight 轻量映射为 `MemoryRecord`，供 `MemoryIndexWriter` 生成 MEMORY.md 使用。
    ///
    /// 这不是完整的双向转换——仅抽取 MEMORY.md 索引和话题文件所需字段：
    /// `id`、`title`（取 summary 首行）、`summary`、`scope`、`retentionPolicy`、时间戳。
    ///
    /// 用于在 `memory_write` 工具写入 `RMSInsightStore` 后，同步更新文件系统层的索引。
    func toMemoryRecord() -> MemoryRecord {
        let effectiveDate = updatedAt ?? Date()
        let title = titleFromSummary()

        return MemoryRecord(
            id: id,
            layer: .semantic,
            kind: .semantic,
            domainProfile: "rms",
            scope: scope ?? .user,
            title: title,
            summary: summary,
            payload: .text(summary),
            source: .tool(name: "memory_write"),
            sourceRefs: [],
            confidence: confidence,
            verificationStatus: .unverified,
            retentionPolicy: .persistent,
            createdAt: effectiveDate,
            updatedAt: effectiveDate
        )
    }

    // MARK: - Private

    private func titleFromSummary() -> String {
        let firstLine = summary
            .split(whereSeparator: { $0.isNewline })
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let candidate = firstLine.isEmpty ? summary : firstLine
        let truncated = String(candidate.prefix(80))
        return truncated.isEmpty ? "Memory" : truncated
    }
}
