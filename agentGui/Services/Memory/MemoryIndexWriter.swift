import Foundation

/// 从 `[MemoryRecord]` 构建 `MEMORY.md` 索引内容和话题文件列表。
///
/// 纯逻辑，无 I/O。对齐 Claude Code `memdir.ts` 截断规则：
/// - 最多 200 行（`maxLines`），25 000 字节（`maxBytes`）
/// - 超出时先行截断，再字节截断（在最后 `\n` 处切断）
/// - 附加明确的 WARNING 行
struct MemoryIndexWriter: Sendable {

    static let maxLines = 200
    static let maxBytes = 25_000
    static let hookMaxLength = 120

    struct Output: Sendable {
        var indexContent: String
        var topicFiles: [(filename: String, content: String)]
        var wasTruncated: Bool
    }

    private let topicComposer = MemoryTopicFileComposer()

    func build(records: [MemoryRecord]) -> Output {
        let active = records.filter { $0.retentionPolicy != .archiveOnly }

        guard !active.isEmpty else {
            return Output(indexContent: "", topicFiles: [], wasTruncated: false)
        }

        // 按 scope.namespace 再按 createdAt 排序，保证稳定顺序
        let sorted = active.sorted {
            if $0.scope.namespace == $1.scope.namespace {
                return $0.createdAt < $1.createdAt
            }
            return $0.scope.namespace < $1.scope.namespace
        }

        var indexLines: [String] = []
        var topicFiles: [(String, String)] = []

        for record in sorted {
            let filename = MemoryTopicFilename.filename(for: record)
            let hook = hookText(record)
            let entry = "- [\(record.title)](\(filename)) — \(hook)"
            indexLines.append(entry)
            topicFiles.append((filename, topicComposer.compose(record: record)))
        }

        let truncated = truncate(lines: indexLines)
        return Output(
            indexContent: truncated.content,
            topicFiles: topicFiles,
            wasTruncated: truncated.wasTruncated
        )
    }

    // MARK: - Private

    private func hookText(_ record: MemoryRecord) -> String {
        let summary = record.summary
        if summary.count <= Self.hookMaxLength {
            return summary
        }
        return String(summary.prefix(Self.hookMaxLength - 1)) + "…"
    }

    private struct TruncationResult {
        var content: String
        var wasTruncated: Bool
    }

    private func truncate(lines: [String]) -> TruncationResult {
        let wasLineTruncated = lines.count > Self.maxLines
        let truncatedLines = wasLineTruncated
            ? Array(lines.prefix(Self.maxLines))
            : lines

        var content = truncatedLines.joined(separator: "\n")
        let wasByteTruncated = content.utf8.count > Self.maxBytes

        if wasByteTruncated {
            // 字节截断：在 maxBytes 之前的最后一个换行符处切断
            let allowedBytes = Self.maxBytes
            let utf8 = content.utf8
            let cutIndex = utf8.index(utf8.startIndex, offsetBy: allowedBytes, limitedBy: utf8.endIndex) ?? utf8.endIndex
            if let candidate = String(utf8.prefix(upTo: cutIndex)) {
                if let lastNewline = candidate.lastIndex(of: "\n") {
                    content = String(candidate[..<lastNewline])
                } else {
                    content = candidate
                }
            }
        }

        let wasTruncated = wasLineTruncated || wasByteTruncated
        if wasTruncated {
            let reason: String
            if wasLineTruncated && !wasByteTruncated {
                reason = "\(lines.count) lines (limit: \(Self.maxLines))"
            } else if wasByteTruncated && !wasLineTruncated {
                let kb = String(format: "%.1f", Double(lines.joined(separator: "\n").utf8.count) / 1024)
                reason = "\(kb)KB (limit: \(Self.maxBytes / 1000)KB) — index entries are too long"
            } else {
                reason = "\(lines.count) lines and \(lines.joined(separator: "\n").utf8.count) bytes"
            }
            content += "\n\n> WARNING: MEMORY.md is \(reason). Only part was loaded. Keep index entries under ~150 chars; move detail into topic files."
        }

        return TruncationResult(content: content, wasTruncated: wasTruncated)
    }
}

// MARK: - String UTF8 prefix helper

private extension String {
    init?(_ utf8View: Substring.UTF8View) {
        self.init(bytes: utf8View, encoding: .utf8)
    }
}
