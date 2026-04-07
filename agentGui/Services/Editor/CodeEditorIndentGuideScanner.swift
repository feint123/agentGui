import Foundation

// MARK: - Model

/// 一行的缩进层级信息。
struct CodeEditorIndentGuideLevel: Equatable, Sendable {
    /// 0-indexed 缩进层级。level=0 表示无缩进（在列 0）。
    /// 空行时 level 由相邻非空行推断（min of prev/next non-blank level），调用方负责填充。
    let level: Int
    let isBlankLine: Bool
}

// MARK: - Scanner

/// 从行文本片段（行首 N 个字符）计算缩进层级。
/// 仅依赖 `indentWidth`（>= 1）和 `useTabs: Bool`，无副作用。
enum CodeEditorIndentGuideScanner {

    /// 给定行首内容（可以是整行 String），返回缩进层级（0-indexed）。
    /// - spaces 模式：前缀连续空格数 / indentWidth（向下取整）
    /// - tabs 模式：前缀连续 \t 字符数
    static func indentLevel(
        forLinePrefix prefix: some StringProtocol,
        indentWidth: Int,
        useTabs: Bool
    ) -> Int {
        guard indentWidth > 0 else { return 0 }
        if useTabs {
            var count = 0
            for ch in prefix.unicodeScalars {
                guard ch == "\t" else { break }
                count += 1
            }
            return count
        } else {
            var count = 0
            for ch in prefix.unicodeScalars {
                guard ch == " " else { break }
                count += 1
            }
            return count / indentWidth
        }
    }

    /// 判断一行是否为空行（仅含空白字符或为空字符串）。
    static func isBlankLine(_ line: some StringProtocol) -> Bool {
        line.unicodeScalars.allSatisfy { $0 == " " || $0 == "\t" }
    }

    /// 批量处理行文本数组，返回每行的 CodeEditorIndentGuideLevel。
    /// 空行的 level 由相邻非空行推断（min of prev and next non-blank level），
    /// 若无相邻非空行则为 0。
    static func computeLevels(
        forLines lines: [String],
        indentWidth: Int,
        useTabs: Bool
    ) -> [CodeEditorIndentGuideLevel] {
        // 第一遍：直接计算
        var raw: [(level: Int, isBlank: Bool)] = lines.map { line in
            let blank = isBlankLine(line)
            let lvl = blank ? 0 : indentLevel(forLinePrefix: line, indentWidth: indentWidth, useTabs: useTabs)
            return (lvl, blank)
        }

        // 第二遍：空行填充（取前后非空行的最小值）
        let rawCount = raw.count
        for i in raw.indices where raw[i].isBlank {
            var prevLevel = 0
            var j = i - 1
            while j >= 0 {
                if !raw[j].isBlank { prevLevel = raw[j].level; break }
                j -= 1
            }
            var nextLevel = 0
            var k = i + 1
            while k < rawCount {
                if !raw[k].isBlank { nextLevel = raw[k].level; break }
                k += 1
            }
            raw[i].level = min(prevLevel, nextLevel)
        }

        return raw.map { CodeEditorIndentGuideLevel(level: $0.level, isBlankLine: $0.isBlank) }
    }
}
