// agentGui/Models/CodeEditorCompletionModels.swift
import Foundation

// MARK: - LSP Completion Item Kind

/// 对应 LSP CompletionItem.kind
enum LSPCompletionItemKind: Int, Sendable {
    case text = 1, method, function, constructor, field
    case variable, `class`, interface, module, property
    case unit, value, `enum`, keyword, snippet
    case color, file, reference, folder, enumMember
    case constant, `struct`, event, `operator`, typeParameter
}

// MARK: - LSP Insert Text Format

/// 对应 LSP CompletionItem.insertTextFormat
enum LSPInsertTextFormat: Int, Sendable {
    case plainText = 1
    case snippet = 2
}

// MARK: - LSP Completion Trigger Kind

/// 触发类型，对应 LSP CompletionTriggerKind
enum LSPCompletionTriggerKind: Int, Sendable {
    case invoked = 1            // Ctrl+Space / 手动
    case triggerCharacter = 2   // 用户键入了 triggerCharacter（如 ".", ":"）
    case triggerForIncomplete = 3
}

// MARK: - CodeEditorCompletionItem

/// 一条 LSP CompletionItem 的本地表示
struct CodeEditorCompletionItem: Identifiable, Equatable, Sendable {
    let id: UUID
    let label: String          // 展示标签（label from LSP）
    let detail: String?        // 右侧暗色补充文字（detail from LSP）
    let documentation: String? // 展开文档（documentation.value from LSP）
    let kind: LSPCompletionItemKind?
    let insertText: String     // 实际插入文本（insertText ?? label）
    let insertTextFormat: LSPInsertTextFormat // plainText(1) | snippet(2)
    let filterText: String     // 用于客户端前缀过滤（filterText ?? label）

    init(
        id: UUID = UUID(),
        label: String,
        detail: String? = nil,
        documentation: String? = nil,
        kind: LSPCompletionItemKind? = nil,
        insertText: String? = nil,
        insertTextFormat: LSPInsertTextFormat = .plainText,
        filterText: String? = nil
    ) {
        self.id = id
        self.label = label
        self.detail = detail
        self.documentation = documentation
        self.kind = kind
        self.insertText = insertText ?? label
        self.insertTextFormat = insertTextFormat
        self.filterText = filterText ?? label
    }
}

// MARK: - CodeEditorCompletionSession

/// 一次补全会话的状态快照（不可变，便于传给 Panel 渲染）
struct CodeEditorCompletionSession: Equatable, Sendable {
    /// 请求时的光标 utf16 偏移
    let cursorOffset: Int
    /// 已键入的前缀词（用于 overwriteBefore 计算）
    let prefixWord: String
    /// 经前缀过滤后的候选项（最多 viewLimit 条）
    let items: [CodeEditorCompletionItem]
    /// 当前选中索引
    let selectedIndex: Int
    /// 是否正在加载
    let isLoading: Bool

    static let loading = CodeEditorCompletionSession(
        cursorOffset: 0,
        prefixWord: "",
        items: [],
        selectedIndex: 0,
        isLoading: true
    )

    func withSelectedIndex(_ index: Int) -> CodeEditorCompletionSession {
        CodeEditorCompletionSession(
            cursorOffset: cursorOffset,
            prefixWord: prefixWord,
            items: items,
            selectedIndex: max(0, min(index, items.count - 1)),
            isLoading: isLoading
        )
    }
}

// MARK: - CompletionTriggerContext

/// 触发上下文（类比 VSCode LineContext）
struct CompletionTriggerContext: Sendable {
    let cursorOffset: Int       // utf16 offset in full document
    let prefixWord: String      // word fragment before cursor (e.g. "myFu")
    let triggerKind: LSPCompletionTriggerKind
    let triggerCharacter: String? // only set when triggerKind == .triggerCharacter

    /// 是否满足自动触发条件：光标末尾有至少 1 个非数字词字符
    /// 对应 VSCode LineContext.shouldAutoTrigger
    static func shouldAutoTrigger(prefixWord: String) -> Bool {
        guard !prefixWord.isEmpty else { return false }
        // 不为纯数字
        if prefixWord.allSatisfy({ $0.isNumber }) { return false }
        return true
    }
}

// MARK: - Insertion Result

struct CompletionInsertionResult {
    let newText: String
    let newCursorOffset: Int  // utf16 offset in newText
}

// MARK: - CodeEditorCompletionInserter

/// 纯函数辅助：把补全项应用到文本字符串，返回新文本和新光标位置。
/// 对应 VSCode SuggestController._insertSuggestion 的核心逻辑。
enum CodeEditorCompletionInserter {

    /// 将补全项应用到文本。
    /// - Parameters:
    ///   - item: 选中的补全项
    ///   - text: 当前全文
    ///   - cursorOffset: 当前光标 utf16 偏移
    ///   - prefixWord: 光标前已键入的词前缀（用来计算 overwriteBefore）
    static func apply(
        item: CodeEditorCompletionItem,
        to text: String,
        cursorOffset: Int,
        prefixWord: String
    ) -> CompletionInsertionResult {
        let utf16 = text.utf16
        let overwriteBefore = prefixWord.utf16.count  // 替换光标前 prefixWord 长度的字符
        let replaceStart = max(0, cursorOffset - overwriteBefore)
        let replaceEnd = cursorOffset  // 首轮不做 overwriteAfter（insert mode）

        guard replaceStart <= replaceEnd,
              replaceEnd <= utf16.count else {
            // 越界保护
            return CompletionInsertionResult(newText: text, newCursorOffset: cursorOffset)
        }

        var insertString = item.insertText
        let finalCursorOffset: Int

        switch item.insertTextFormat {
        case .snippet:
            // 首轮 snippet 支持：找到 $0 位置作为光标停止点，去掉 $0 标记
            let processed = processSnippet(insertString)
            insertString = processed.text
            finalCursorOffset = replaceStart + processed.cursorPositionInInsertion
        case .plainText:
            finalCursorOffset = replaceStart + insertString.utf16.count
        }

        // 拼接新文本
        let startIndex = utf16.index(utf16.startIndex, offsetBy: replaceStart)
        let endIndex = utf16.index(utf16.startIndex, offsetBy: replaceEnd)
        var newUTF16 = Array(utf16[utf16.startIndex..<startIndex])
        newUTF16 += Array(insertString.utf16)
        newUTF16 += Array(utf16[endIndex...])
        let newText = String(decoding: newUTF16, as: UTF16.self)

        return CompletionInsertionResult(newText: newText, newCursorOffset: finalCursorOffset)
    }

    // MARK: - Snippet processing (basic: $0 only)

    private struct SnippetProcessedResult {
        let text: String
        let cursorPositionInInsertion: Int  // utf16 in text
    }

    private static func processSnippet(_ snippet: String) -> SnippetProcessedResult {
        // 找到第一个 $0 位置，移除该标记，光标停在此处
        if let range = snippet.range(of: "$0") {
            let before = String(snippet[snippet.startIndex..<range.lowerBound])
            let after = String(snippet[range.upperBound...])
            // 去掉其他 $N 占位
            let cleaned = (before + after).replacingOccurrences(
                of: #"\$\{?\d+(?::[^}]*)?\}?"#,
                with: "",
                options: .regularExpression
            )
            let cursorPos = before.utf16.count
            return SnippetProcessedResult(text: cleaned, cursorPositionInInsertion: cursorPos)
        }
        // 无 $0：去掉所有 placeholder 标记，光标在末尾
        let cleaned = snippet.replacingOccurrences(
            of: #"\$\{?\d+(?::[^}]*)?\}?"#,
            with: "",
            options: .regularExpression
        )
        return SnippetProcessedResult(text: cleaned, cursorPositionInInsertion: cleaned.utf16.count)
    }
}
