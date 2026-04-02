import Foundation
import SwiftAnthropic

extension ClaudeService {

    /// 构建 memory extraction subagent 的受限工具集。
    ///
    /// 只包含：
    /// - `memory_write`（写入长期记忆）
    /// - `read_file`（可选读取文件内容，减少幻觉）
    ///
    /// 不包含：bash、run_subagent、web_search、lsp_* 等重型工具，
    /// 确保提取 subagent 不会发起副作用或创建递归 loop。
    func buildExtractionTools(settings: AppSettings) -> [MessageParameter.Tool] {
        // 从完整工具集里筛选允许的工具名
        let allowed: Set<String> = ["memory_write", "read_file"]
        let allTools = buildTools(modelId: settings.selectedModel, settings: settings)
        return allTools.filter { tool in
            let name = toolNameForExtraction(from: tool)
            return name.map { allowed.contains($0) } ?? false
        }
    }

    /// 通过 Mirror 安全提取 MessageParameter.Tool 的工具名。
    func toolNameForExtraction(from tool: MessageParameter.Tool) -> String? {
        extractStringFromMirror(labeled: "name", from: Mirror(reflecting: tool))
    }

    private func extractStringFromMirror(labeled target: String, from mirror: Mirror) -> String? {
        for child in mirror.children {
            if child.label == target, let value = child.value as? String {
                return value
            }
            let childMirror = Mirror(reflecting: child.value)
            if let value = extractStringFromMirror(labeled: target, from: childMirror) {
                return value
            }
        }
        return nil
    }
}
