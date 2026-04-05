//
//  ClaudeService+ToolBuilder.swift
//  agentGui
//

import Foundation
import SwiftAnthropic

// MARK: - Tool List Builder

extension ClaudeService {

    func buildTools(modelId: String, settings: AppSettings, enabledSkills: [Skill] = [], isSubagent: Bool = false) -> [MessageParameter.Tool] {
        var tools: [MessageParameter.Tool] = []
        let registry = DefaultToolRegistry()

        if settings.enableTextEditorTool,
           let definition = registry.definition(for: "str_replace_based_edit_tool") {
            tools.append(definition.makeAnthropicTool())
        }

        if settings.enableBashTool,
           let definition = registry.definition(for: "bash") {
            tools.append(definition.makeAnthropicTool())
        }

        if let definition = registry.definition(for: "read_tool_payload") {
            tools.append(definition.makeAnthropicTool())
        }

        if settings.enableWebSearchTool,
           let definition = registry.definition(for: "web_search") {
            tools.append(definition.makeAnthropicTool())
        }

        if settings.enableWebFetchTool,
           let definition = registry.definition(for: "web_fetch") {
            tools.append(definition.makeAnthropicTool())
        }

        if settings.enableLSPTools {
            let lspToolIDs = [
                "lsp_definition",
                "lsp_references",
                "lsp_hover",
                "lsp_document_symbols",
                "lsp_workspace_symbols",
                "lsp_diagnostics",
                "lsp_list_servers",
                "lsp_server_status"
            ]
            for toolID in lspToolIDs {
                if let definition = registry.definition(for: toolID) {
                    tools.append(definition.makeAnthropicTool())
                }
            }
        }

        if !enabledSkills.isEmpty {
            if let definition = registry.definition(for: "read_skill") {
                tools.append(definition.makeAnthropicTool())
            }
            if let definition = registry.definition(for: "skill_invoke") {
                tools.append(definition.makeAnthropicTool())
            }
        }

        // run_subagent: only available to the main agent (not inside subagent loops)
        if !isSubagent {
            let context = ToolDefinitionBuildContext.default
            if let definition = registry.definition(for: "run_subagent") {
                tools.append(definition.makeAnthropicTool(context: context))
            }
        }

        // update_todo_list: available to all agents (main and subagent)
        if let definition = registry.definition(for: "update_todo_list") {
            tools.append(definition.makeAnthropicTool())
        }

        // create_execution_plan: records a structured plan before tackling complex tasks
        if let definition = registry.definition(for: "create_execution_plan") {
            tools.append(definition.makeAnthropicTool())
        }

        // verify_completion: explicitly states what was and wasn't verified before finishing
        if let definition = registry.definition(for: "verify_completion") {
            tools.append(definition.makeAnthropicTool())
        }

        // ask_user_question is always available to the main agent only
        if let definition = registry.definition(for: "ask_user_question") {
            tools.append(definition.makeAnthropicTool())
        }

        if let definition = registry.definition(for: "analyze_image") {
            tools.append(definition.makeAnthropicTool())
        }

        if let definition = registry.definition(for: "read_pdf") {
            tools.append(definition.makeAnthropicTool())
        }

        // memory_write: always available — persist long-term facts as Markdown files to ~/agentgui/memory/
        if let definition = registry.definition(for: "memory_write") {
            tools.append(definition.makeAnthropicTool())
        }

        return tools
    }

    // MARK: - Extraction Tools

    /// 构建 memory extraction subagent 的受限工具集。
    ///
    /// 从完整工具集中筛选出 `memory_write`（M-04 后直接写 `.md` 文件），
    /// 供 `SessionMemoryExtractorService` 使用。
    ///
    /// 不包含：bash、run_subagent、str_replace_based_edit_tool 等重型工具，
    /// 确保提取 subagent 不会产生副作用或创建递归 loop。
    func buildExtractionTools(settings: AppSettings) -> [MessageParameter.Tool] {
        let allowed: Set<String> = ["memory_write"]
        let allTools = buildTools(modelId: settings.selectedModel, settings: settings)
        return allTools.filter { tool in
            toolNameForExtraction(from: tool).map { allowed.contains($0) } ?? false
        }
    }

    /// 构建 session memory update subagent 的受限工具集。
    ///
    /// 仅包含：
    /// - `str_replace_based_edit_tool`（EditTool，用于更新 summary.md 各节内容）
    /// - `read_file`（ReadTool，用于读取 summary.md 当前内容作为上下文）
    ///
    /// 对齐 Claude Code 中 forked agent 使用 FileEditTool + FileReadTool 的模式。
    func buildSessionMemoryTools(settings: AppSettings) -> [MessageParameter.Tool] {
        let allowed: Set<String> = ["str_replace_based_edit_tool", "read_file"]
        let allTools = buildTools(modelId: settings.selectedModel, settings: settings)
        return allTools.filter { tool in
            toolNameForExtraction(from: tool).map { allowed.contains($0) } ?? false
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
