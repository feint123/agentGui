import Foundation

/// 将 `git diff -U0` 输出的 unified diff 文本解析为行级变更映射。
///
/// 设计约束：
/// - 只处理 hunk headers（`@@ ... @@` 行），不逐行解析 `+/-` 内容。
/// - 纯添加 → 每新行标 `.added`；纯删除 → 在插入点行标 `.deleted`；
///   混合 → min(oldCount,newCount) 行标 `.modified`，多余的新行标 `.added`。
/// - 线程安全：无状态，全为静态方法。
enum UnifiedDiffParser {

    /// 解析 unified diff 文本，返回 `[newFileLineNumber: diffKind]`。
    /// - Parameter diffText: `git diff -U0 HEAD -- <file>` 的 stdout。
    static func parse(_ diffText: String) -> [Int: CodeEditorGitDiffKind] {
        guard !diffText.isEmpty else { return [:] }
        var result: [Int: CodeEditorGitDiffKind] = [:]
        let hunkHeaderPrefix = "@@ "

        for line in diffText.split(whereSeparator: \.isNewline) {
            let str = String(line)
            guard str.hasPrefix(hunkHeaderPrefix) else { continue }
            guard let parsed = parseHunkHeader(str) else { continue }

            let (oldCount, newStart, newCount) = parsed

            if newCount == 0 {
                // 纯删除：标记插入点行，文件头部删除时标记在行 1
                let marker = max(newStart, 1)
                result[marker] = .deleted
            } else if oldCount == 0 {
                // 纯添加
                for offset in 0..<newCount {
                    let lineNumber = newStart + offset
                    if result[lineNumber] == nil {
                        result[lineNumber] = .added
                    }
                }
            } else {
                // 混合（both sides present）：
                // min(oldCount,newCount) 行为修改，多余的新行为添加
                let modifiedCount = min(oldCount, newCount)
                for offset in 0..<modifiedCount {
                    let lineNumber = newStart + offset
                    result[lineNumber] = .modified
                }
                for offset in modifiedCount..<newCount {
                    let lineNumber = newStart + offset
                    if result[lineNumber] == nil {
                        result[lineNumber] = .added
                    }
                }
            }
        }
        return result
    }

    // MARK: - Private

    /// 解析格式 `@@ -<oldStart>[,<oldCount>] +<newStart>[,<newCount>] @@ ...`
    /// 返回 `(oldCount, newStart, newCount)`
    private static func parseHunkHeader(_ line: String) -> (oldCount: Int, newStart: Int, newCount: Int)? {
        // 提取 `@@` 之间的内容
        let parts = line.components(separatedBy: "@@")
        guard parts.count >= 2 else { return nil }
        let rangeString = parts[1].trimmingCharacters(in: .whitespaces)
        // rangeString example: "-3,2 +5,4"  or  "-5 +5"
        let sides = rangeString.components(separatedBy: " ")
        guard sides.count >= 2 else { return nil }

        let oldSide = sides[0]  // e.g. "-3,2"
        let newSide = sides[1]  // e.g. "+5,4"

        guard oldSide.hasPrefix("-"), newSide.hasPrefix("+") else { return nil }

        let oldCount = parseCount(String(oldSide.dropFirst()))
        let (newStart, newCount) = parseStartAndCount(String(newSide.dropFirst()))

        return (oldCount, newStart, newCount)
    }

    /// 解析 "start,count" 或 "start"（count 默认为 1）
    private static func parseStartAndCount(_ s: String) -> (start: Int, count: Int) {
        let comps = s.components(separatedBy: ",")
        let start = Int(comps[0]) ?? 1
        let count = comps.count > 1 ? (Int(comps[1]) ?? 1) : 1
        return (start, count)
    }

    /// 解析 "start,count" 中的 count 部分（仅取 count），不关心 start
    private static func parseCount(_ s: String) -> Int {
        let comps = s.components(separatedBy: ",")
        return comps.count > 1 ? (Int(comps[1]) ?? 1) : 1
    }
}
