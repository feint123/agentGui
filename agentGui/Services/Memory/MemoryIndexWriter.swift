import Foundation

/// MEMORY.md 索引截断工具。
///
/// `build(records:)` 已在 M-02 移除。`MemoryIndexFileSystem.rebuildFromDirectory()`
/// 从文件系统扫描驱动重建，内部通过此类的 `truncate(lines:)` 方法截断。
struct MemoryIndexWriter: Sendable {

    static let maxLines = 200
    static let maxBytes = 25_000
    static let hookMaxLength = 120

    struct TruncationResult: Sendable {
        var content: String
        var wasTruncated: Bool
    }

    func truncate(lines: [String]) -> TruncationResult {
        let wasLineTruncated = lines.count > Self.maxLines
        let truncatedLines = wasLineTruncated
            ? Array(lines.prefix(Self.maxLines))
            : lines

        var content = truncatedLines.joined(separator: "\n")
        let wasByteTruncated = content.utf8.count > Self.maxBytes

        if wasByteTruncated {
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
