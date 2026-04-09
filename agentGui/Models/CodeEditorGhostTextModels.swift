// agentGui/Models/CodeEditorGhostTextModels.swift
import Foundation

// MARK: - GhostTextDisplayLine

struct GhostTextDisplayLine: Equatable {
    /// 相对光标行的偏移（0 = 光标所在行，1 = 下一行，…）
    let lineOffset: Int
    let text: String
}

// MARK: - CodeEditorGhostTextSnapshot

struct CodeEditorGhostTextSnapshot: Equatable {
    static let maxDisplayLines = 20

    /// 代际标记，用于取消过期回写
    let generation: Int
    /// Ghost text 插入点（UTF-16 offset，等于光标位置）
    let insertionOffset: Int
    /// 完整 ghost text（可能多行）
    let text: String
    /// 预计算的分行显示结构，最多 maxDisplayLines 行
    let displayLines: [GhostTextDisplayLine]

    init(generation: Int, insertionOffset: Int, text: String) {
        self.generation = generation
        self.insertionOffset = insertionOffset
        self.text = text
        let rawLines = text.components(separatedBy: "\n")
        self.displayLines = rawLines
            .prefix(Self.maxDisplayLines)
            .enumerated()
            .map { GhostTextDisplayLine(lineOffset: $0.offset, text: $0.element) }
    }

    /// 返回 text 中"下一词"的 Range，对齐 Zed `EditPredictionGranularity::Word`。
    ///
    /// 规则（参照 Zed editor.rs accept_partial_edit_prediction / VSCode acceptNextWord）：
    /// 1. 先尝试取连续"词字母"（isLetter || isNumber，即 Unicode 字母数字）
    /// 2. 若第一字符非词字母（标点 / 空白 / 符号），则取连续的"非词字母"序列
    ///    - 空白序列：所有空白（不跨换行）归为一个块
    ///    - 标点序列：每次只取到下一个字母或换行
    /// 3. 换行符 '\n' 不被跨越（返回 nil 以外的情况均在第一行内发生）
    func nextWordRange() -> Range<String.Index>? {
        guard !text.isEmpty else { return nil }
        let start = text.startIndex
        guard text[start] != "\n" else { return nil }

        // 阶段 1：取连续字母数字（词核心）
        var idx = start
        while idx < text.endIndex, text[idx].isLetter || text[idx].isNumber {
            idx = text.index(after: idx)
        }
        if idx > start {
            return start..<idx
        }

        // 阶段 2：首字符非字母数字 → 取连续"非字母数字且非换行"序列
        idx = start
        let firstIsWhitespace = text[idx].isWhitespace
        while idx < text.endIndex {
            let ch = text[idx]
            if ch == "\n" { break }
            if firstIsWhitespace, !ch.isWhitespace { break }
            if !firstIsWhitespace, ch.isLetter || ch.isNumber { break }
            idx = text.index(after: idx)
        }
        return idx > start ? start..<idx : nil
    }
}
