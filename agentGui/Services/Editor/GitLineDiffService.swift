import Foundation

/// 异步查询单文件相对 HEAD 的行级 diff。
/// Actor 保证内部缓存写入线程安全。
actor GitLineDiffService {

    private let commandRunner: GitCommandRunning

    /// 上一次查询结果缓存，用于去重（同文件连续查询时跳过相同版本）
    private var cachedResult: (fileURL: URL, result: [Int: CodeEditorGitDiffKind])?

    init(commandRunner: GitCommandRunning = ProcessGitCommandRunner()) {
        self.commandRunner = commandRunner
    }

    /// 获取指定文件相对 HEAD 的行级 diff 映射。
    /// - Parameters:
    ///   - fileURL: 被查询文件的绝对 URL。
    ///   - workspaceRoot: Git 仓库根目录（用于计算相对路径及作为 git 工作目录）。
    /// - Returns: `[lineNumber: diffKind]`，未追踪文件或出错时返回空映射。
    func fetchLineDiff(
        fileURL: URL,
        workspaceRoot: URL
    ) async -> [Int: CodeEditorGitDiffKind] {
        let relativePath = fileURL.path(percentEncoded: false)
            .replacingOccurrences(of: workspaceRoot.path(percentEncoded: false) + "/", with: "")

        let result: GitCommandResult
        do {
            result = try await commandRunner.run(
                arguments: ["diff", "-U0", "HEAD", "--", relativePath],
                workingDirectory: workspaceRoot
            )
        } catch {
            return [:]
        }

        guard result.exitCode == 0 else { return [:] }

        let diffMap = UnifiedDiffParser.parse(result.stdout)
        cachedResult = (fileURL: fileURL, result: diffMap)
        return diffMap
    }
}
