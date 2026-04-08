import Foundation

/// 对应 LSP InlayHintKind（spec §3.17.12）
/// 1 = Type（如 `: String`），2 = Parameter（如 `label:`）
enum CodeEditorInlayHintKind: Int, Sendable, Equatable {
    case type = 1
    case parameter = 2
    /// fallback：kind 未知时按 type 显示
    case unknown = 0

    init(rawValue: Int) {
        switch rawValue {
        case 1: self = .type
        case 2: self = .parameter
        default: self = .unknown
        }
    }
}

/// 单个来自 LSP 的内联 Hint，完全值类型 + Sendable。
///
/// - `line` / `character`：1-based（agentGui 内部约定），从 LSP 0-based 转换后存储。
/// - `label`：纯文字（不含 labelParts 结构体，首轮只要 string label）。
/// - `paddingLeft` / `paddingRight`：是否在 hint 文本前/后插入额外间距（一个半角空格）。
struct CodeEditorInlayHint: Equatable, Sendable {
    let line: Int           // 1-based 行号
    let character: Int      // 1-based 列号（hint 紧贴该字符右侧绘制）
    let label: String       // 展示文字，已截断到 maxLabelLength
    let kind: CodeEditorInlayHintKind
    let paddingLeft: Bool
    let paddingRight: Bool
}

/// Coordinator 传给 CodeEditorPlatformTextView 的快照。
/// 以 documentVersion 作为有效性标记——版本不一致时 textView 应忽略本快照。
struct CodeEditorInlayHintSnapshot: Sendable {
    let documentVersion: Int
    /// 按 line（1-based）索引的 hints，只含当前可见区 + buffer 内的行
    let hintsByLine: [Int: [CodeEditorInlayHint]]

    static let empty = CodeEditorInlayHintSnapshot(documentVersion: -1, hintsByLine: [:])

    init(documentVersion: Int, hintsByLine: [Int: [CodeEditorInlayHint]]) {
        self.documentVersion = documentVersion
        self.hintsByLine = hintsByLine
    }

    /// 从扁平数组构建 snapshot
    init(documentVersion: Int, hints: [CodeEditorInlayHint]) {
        self.documentVersion = documentVersion
        var byLine: [Int: [CodeEditorInlayHint]] = [:]
        for hint in hints {
            byLine[hint.line, default: []].append(hint)
        }
        // 每行内按 character 升序
        for key in byLine.keys {
            byLine[key]!.sort { $0.character < $1.character }
        }
        self.hintsByLine = byLine
    }
}
