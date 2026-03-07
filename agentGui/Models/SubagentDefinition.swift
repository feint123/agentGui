//
//  SubagentDefinition.swift
//  agentGui
//
//  Defines built-in subagent specializations that the main agent can delegate tasks to.
//

import Foundation

// MARK: - Subagent Definition

/// 描述一个内置子代理的配置：名称、系统提示、可用工具等
struct SubagentDefinition {
    /// 机器可读标识符（用于 run_subagent 工具的 agent_name 参数）
    let name: String

    /// 人类可读的显示名称
    let displayName: String

    /// 一句话描述，供主 Agent 选择时参考
    let description: String

    /// 子代理的系统提示
    let systemPrompt: String

    /// 是否启用文本编辑工具（str_replace_based_edit_tool / str_replace_editor）
    let enableTextEditor: Bool

    /// 是否启用 bash 工具
    let enableBash: Bool

    /// 最大迭代轮次（防止失控循环）
    let maxRounds: Int
}

// MARK: - Built-in Subagents

extension SubagentDefinition {

    /// 所有内置子代理（按名称索引）
    static let all: [SubagentDefinition] = [
        explorer,
        coder,
        reviewer,
        executor,
        summarizer,
        writer,
        outline_planner,
    ]

    /// 按名称查找子代理
    static func find(named name: String) -> SubagentDefinition? {
        all.first { $0.name == name }
    }

    // MARK: Explorer — 代码探索者

    static let explorer = SubagentDefinition(
        name: "explorer",
        displayName: "探索者",
        description: "快速阅读代码库、文件或文档，回答结构性和内容性问题。只读，不修改文件。",
        systemPrompt: """
        You are a focused code exploration assistant. Your job is to read files, understand code \
        structure, and answer questions about the codebase clearly and concisely.

        Rules:
        - Use the text editor tool ONLY with the "view" command. Do NOT create, edit, or delete files.
        - Be concise: summarize findings rather than quoting entire files verbatim.
        - If a file is large, read only the relevant sections.
        - Return a clear, structured answer at the end.
        """,
        enableTextEditor: true,
        enableBash: false,
        maxRounds: 8
    )

    // MARK: Coder — 代码编写者

    static let coder = SubagentDefinition(
        name: "coder",
        displayName: "编写者",
        description: "实现代码变更：编写新文件或修改现有文件，可运行命令验证。",
        systemPrompt: """
        You are a focused coding assistant. Your job is to implement the exact changes described \
        in the task using the text editor and bash tools.

        Rules:
        - Read relevant files first before making changes.
        - Make minimal, targeted edits. Do not refactor code beyond what is asked.
        - Use bash to run build or test commands only when needed to verify your changes.
        - Return a concise summary of what was changed and why.
        """,
        enableTextEditor: true,
        enableBash: true,
        maxRounds: 16
    )

    // MARK: Reviewer — 代码审查者

    static let reviewer = SubagentDefinition(
        name: "reviewer",
        displayName: "审查者",
        description: "审查代码质量、安全性、规范性，返回结构化审查报告。只读，不修改文件。",
        systemPrompt: """
        You are a careful code reviewer. Your job is to read the specified code and produce a \
        structured review covering correctness, security, performance, and code style.

        Rules:
        - Use the text editor tool ONLY with the "view" command. Do NOT modify any files.
        - Organize findings by severity: Critical / Warning / Suggestion.
        - Be specific: point to file paths and line numbers where relevant.
        - Return a clear, actionable review report.
        """,
        enableTextEditor: true,
        enableBash: false,
        maxRounds: 8
    )

    // MARK: Executor — 命令执行者

    static let executor = SubagentDefinition(
        name: "executor",
        displayName: "执行者",
        description: "运行 bash 命令（构建、测试、脚本等），返回结果摘要。",
        systemPrompt: """
        You are a focused command executor. Your job is to run the bash commands described in \
        the task and return a concise summary of the results.

        Rules:
        - Run only the commands described in the task.
        - If a command fails, diagnose the error and attempt to fix it (max 2 retries).
        - Return a clear summary: what ran, what succeeded, what failed, and key output.
        - Do not run destructive commands (rm -rf, drop database, etc.) unless explicitly instructed.
        """,
        enableTextEditor: false,
        enableBash: true,
        maxRounds: 8
    )

    // MARK: Summarizer — 内容总结员

    static let summarizer = SubagentDefinition(
        name: "summarizer",
        displayName: "总结员",
        description: "读取文件、文档或代码，生成简洁易读的总结。只读，不修改文件。",
        systemPrompt: """
        You are a concise summarization assistant. Your job is to read the specified content \
        and return a clear, structured summary suitable for someone unfamiliar with the details.

        Rules:
        - Use the text editor tool ONLY with the "view" command. Do NOT modify any files.
        - Read only the sections necessary to produce a complete summary.
        - Structure your output with headings when the content warrants it.
        - Be concise: omit low-value details, focus on what matters most.
        """,
        enableTextEditor: true,
        enableBash: false,
        maxRounds: 6
    )

    // MARK: Writer — 写作者

    static let writer = SubagentDefinition(
        name: "writer",
        displayName: "写作者",
        description: "专业写作辅助：生成、润色、改写、翻译各类文本内容。",
        systemPrompt: """
        You are a professional writing assistant. Your task is to help with various writing needs.

        Capabilities:
        - Generate original content based on prompts
        - Polish and improve existing text
        - Rewrite in different styles (formal, casual, creative, etc.)
        - Translate between languages
        - Expand or summarize content

        Rules:
        - Maintain the original meaning when polishing/rewriting
        - Adapt the style to the specified tone
        - For translation, preserve formatting and structure
        - Return clean, ready-to-use text
        """,
        enableTextEditor: true,
        enableBash: false,
        maxRounds: 8
    )

    // MARK: OutlinePlanner — 大纲规划师

    static let outline_planner = SubagentDefinition(
        name: "outline_planner",
        displayName: "大纲规划师",
        description: "帮助构建文档结构：章节规划、大纲生成、内容组织。",
        systemPrompt: """
        You are an expert at structuring content. Your job is to create well-organized outlines.

        Rules:
        - Analyze the topic and create a logical structure
        - Use clear hierarchy (chapters, sections, subsections)
        - Provide brief descriptions for each section
        - Consider narrative flow and coherence
        - Output as Markdown with proper heading levels
        """,
        enableTextEditor: true,
        enableBash: false,
        maxRounds: 6
    )
}
