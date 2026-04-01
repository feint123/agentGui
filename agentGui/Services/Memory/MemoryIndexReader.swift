import Foundation

/// 从磁盘读取 `MEMORY.md` 并应用与 `MemoryIndexWriter` 相同的截断规则。
///
/// nonisolated struct，执行同步 I/O（文件 ≤25KB，耗时可忽略）。
struct MemoryIndexReader: Sendable {

    struct ReadResult: Sendable {
        var content: String
        var lineCount: Int
        var byteCount: Int
        var wasTruncated: Bool
    }

    /// 读取 `url` 处的 MEMORY.md 文件。
    /// - Returns: 若文件不存在或为空返回 `nil`；否则返回截断后的内容。
    func read(from url: URL) -> ReadResult? {
        guard FileManager.default.fileExists(atPath: url.path),
              let raw = try? String(contentsOf: url, encoding: .utf8),
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return truncate(raw: raw)
    }

    // MARK: - Private

    private func truncate(raw: String) -> ReadResult {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let allLines = trimmed.components(separatedBy: "\n")
        let originalLineCount = allLines.count
        let originalByteCount = trimmed.utf8.count

        let wasLineTruncated = originalLineCount > MemoryIndexWriter.maxLines
        let wasByteTruncated = originalByteCount > MemoryIndexWriter.maxBytes

        if !wasLineTruncated && !wasByteTruncated {
            return ReadResult(
                content: trimmed,
                lineCount: originalLineCount,
                byteCount: originalByteCount,
                wasTruncated: false
            )
        }

        let truncatedLines = wasLineTruncated
            ? Array(allLines.prefix(MemoryIndexWriter.maxLines))
            : allLines
        var content = truncatedLines.joined(separator: "\n")

        if content.utf8.count > MemoryIndexWriter.maxBytes {
            let utf8 = content.utf8
            let cutIndex = utf8.index(
                utf8.startIndex,
                offsetBy: MemoryIndexWriter.maxBytes,
                limitedBy: utf8.endIndex
            ) ?? utf8.endIndex
            if let candidate = String(utf8.prefix(upTo: cutIndex)) {
                if let lastNL = candidate.lastIndex(of: "\n") {
                    content = String(candidate[..<lastNL])
                } else {
                    content = candidate
                }
            }
        }

        let reason: String
        if wasLineTruncated {
            reason = "\(originalLineCount) lines (limit: \(MemoryIndexWriter.maxLines))"
        } else {
            let kb = String(format: "%.1f", Double(originalByteCount) / 1024)
            reason = "\(kb)KB — entries are too long"
        }
        content += "\n\n> WARNING: MEMORY.md is \(reason). Only part was loaded."

        return ReadResult(
            content: content,
            lineCount: originalLineCount,
            byteCount: originalByteCount,
            wasTruncated: true
        )
    }
}

// MARK: - String UTF8 prefix helper

private extension String {
    init?(_ utf8View: Substring.UTF8View) {
        self.init(bytes: utf8View, encoding: .utf8)
    }
}
