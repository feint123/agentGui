import Foundation

/// 括号匹配扫描结果：开括号和闭括号的 utf16 range。
/// openRange 和 closeRange 各占一个字符（在极少数多字节 utf16 情况下也是 1 或 2 个 utf16 unit）。
struct CodeEditorBracketMatchResult: Equatable, Sendable {
    let openRange: NSRange
    let closeRange: NSRange
}

/// 纯值类型括号匹配扫描器。
/// 线性 O(n) 栈扫描，不依赖 Tree-sitter。
struct CodeEditorBracketScanner: Sendable {

    /// 支持的括号对（开 → 闭）
    static let openBrackets: [UInt16] = [
        UInt16(("(" as UnicodeScalar).value),
        UInt16(("[" as UnicodeScalar).value),
        UInt16(("{" as UnicodeScalar).value),
    ]
    static let closeBrackets: [UInt16] = [
        UInt16((")" as UnicodeScalar).value),
        UInt16(("]" as UnicodeScalar).value),
        UInt16(("}" as UnicodeScalar).value),
    ]

    /// 给定 utf16 字符串和光标 utf16 offset，查找匹配括号对。
    /// 检测光标前一字符（index = cursorOffset - 1）和光标当前字符（index = cursorOffset）。
    /// 若在括号字符上，向前/向后线性扫描，找到匹配的另一侧括号。
    /// - Parameter maxSearchDistance: 最大扫描字符数，防止超大文件卡顿，默认 50_000
    static func findMatch(
        in utf16: [UInt16],
        cursorOffset: Int,
        maxSearchDistance: Int = 50_000
    ) -> CodeEditorBracketMatchResult? {
        // Case 1: cursor 在开括号上 → 向前搜索
        if let result = scanForward(utf16: utf16, from: cursorOffset, maxDistance: maxSearchDistance) {
            return result
        }
        // Case 2: cursor 直接在闭括号上 → 向后搜索
        if let result = scanBackward(utf16: utf16, from: cursorOffset, maxDistance: maxSearchDistance) {
            return result
        }
        // Case 3: cursor 紧跟闭括号之后（cursor-1 是闭括号）→ 向后搜索
        if cursorOffset > 0,
           let result = scanBackward(utf16: utf16, from: cursorOffset - 1, maxDistance: maxSearchDistance) {
            return result
        }
        return nil
    }

    /// 给定一个开括号在 startIndex 处，向前搜索其匹配的闭括号。
    static func scanForward(utf16: [UInt16], from startIndex: Int, maxDistance: Int) -> CodeEditorBracketMatchResult? {
        guard startIndex < utf16.count else { return nil }
        let ch = utf16[startIndex]
        guard let pairIndex = openBrackets.firstIndex(of: ch) else { return nil }
        let closeChar = closeBrackets[pairIndex]

        var depth = 1
        var i = startIndex + 1
        let limit = min(utf16.count, startIndex + maxDistance)
        while i < limit {
            let c = utf16[i]
            if c == ch { depth += 1 }
            else if c == closeChar {
                depth -= 1
                if depth == 0 {
                    return CodeEditorBracketMatchResult(
                        openRange: NSRange(location: startIndex, length: 1),
                        closeRange: NSRange(location: i, length: 1)
                    )
                }
            }
            i += 1
        }
        return nil
    }

    /// 给定一个闭括号在 startIndex 处，向后搜索其匹配的开括号。
    static func scanBackward(utf16: [UInt16], from startIndex: Int, maxDistance: Int) -> CodeEditorBracketMatchResult? {
        guard startIndex < utf16.count else { return nil }
        let ch = utf16[startIndex]
        guard let pairIndex = closeBrackets.firstIndex(of: ch) else { return nil }
        let openChar = openBrackets[pairIndex]

        var depth = 1
        var i = startIndex - 1
        let lowerLimit = max(0, startIndex - maxDistance)
        while i >= lowerLimit {
            let c = utf16[i]
            if c == ch { depth += 1 }
            else if c == openChar {
                depth -= 1
                if depth == 0 {
                    return CodeEditorBracketMatchResult(
                        openRange: NSRange(location: i, length: 1),
                        closeRange: NSRange(location: startIndex, length: 1)
                    )
                }
            }
            i -= 1
        }
        return nil
    }
}

extension CodeEditorBracketScanner {
    /// 便利入口：直接接受 String，转为 UTF-16 数组后调用 findMatch。
    static func findMatch(
        in text: String,
        cursorOffset: Int,
        maxSearchDistance: Int = 50_000
    ) -> CodeEditorBracketMatchResult? {
        let utf16Array = Array(text.utf16)
        return findMatch(in: utf16Array, cursorOffset: cursorOffset, maxSearchDistance: maxSearchDistance)
    }
}
