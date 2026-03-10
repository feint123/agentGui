import Foundation

struct MemoryPromptAssembler {
    func render(context: MemoryRuntimeContext) -> String {
        var sections: [String] = []

        let verifiedFacts = context.records.filter {
            $0.layer != .episodic && $0.verificationStatus == .verified && $0.retentionPolicy != .archiveOnly
        }
        let speculativeRecords = context.records.filter {
            $0.layer != .episodic && $0.verificationStatus != .verified && $0.retentionPolicy != .archiveOnly
        }
        let episodicRecords = context.records.filter { $0.layer == .episodic }

        sections.append(renderSection(title: "已验证事实", records: verifiedFacts, emptyState: "暂无已验证事实"))
        sections.append(renderSection(title: "当前推测", records: speculativeRecords, emptyState: "暂无当前推测"))
        sections.append(renderSection(title: "相关事件", records: episodicRecords, emptyState: "暂无相关事件"))
        sections.append(renderWarnings(context.warnings, speculativeRecords: speculativeRecords))

        return sections.joined(separator: "\n\n")
    }

    private func renderSection(title: String, records: [MemoryRecord], emptyState: String) -> String {
        let body: String
        if records.isEmpty {
            body = "- \(emptyState)"
        } else {
            body = records.map { record in
                if record.summary.isEmpty || record.summary == record.title {
                    return "- \(record.title)"
                }
                return "- \(record.title)：\(record.summary)"
            }.joined(separator: "\n")
        }

        return "## \(title)\n\(body)"
    }

    private func renderWarnings(_ warnings: [String], speculativeRecords: [MemoryRecord]) -> String {
        let derivedWarnings = speculativeRecords.map { "未验证：\($0.title)" }
        let mergedWarnings = warnings + derivedWarnings
        let body: String = mergedWarnings.isEmpty
            ? "- 暂无风险或待确认项"
            : mergedWarnings.map { "- \($0)" }.joined(separator: "\n")

        return "## 风险与待确认项\n\(body)"
    }
}