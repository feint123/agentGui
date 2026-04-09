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

    /// 返回 text 中"下一个词"的 Range，供 ⌘→ 按词接受使用。
    /// 规则与 Zed `EditPredictionGranularity.Word` 对齐：
    /// - 若文本以空白开头，先接受连续空白
    /// - 否则接受连续非空白字符
    func nextWordRange() -> Range<String.Index>? {
        guard !text.isEmpty else { return nil }
        let start = text.startIndex
        let firstChar = text[start]
        let isWhitespace = firstChar.isWhitespace && firstChar != "\n"
        let afterFirst = text.index(after: start)
        let rest = text[afterFirst...]
        let boundary = rest.firstIndex(where: { char in
            char.isWhitespace != isWhitespace || char == "\n"
        }) ?? text.endIndex
        return start..<boundary
    }
}
