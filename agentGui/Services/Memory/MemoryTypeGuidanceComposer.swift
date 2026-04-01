import Foundation

/// 生成 memory 类型指导的两个 Markdown 节，供注入 agent system prompt。
///
/// 内容对齐 Claude Code `memoryTypes.ts` 中的
/// `TYPES_SECTION_INDIVIDUAL` 与 `WHAT_NOT_TO_SAVE_SECTION`。
///
/// nonisolated struct，无 I/O，无副作用，可在任意并发上下文调用。
struct MemoryTypeGuidanceComposer: Sendable {

    /// 生成完整的 `## Types of memory` 节。
    func typesSection() -> String {
        """
        ## Types of memory

        There are several discrete types of memory that you can store in your memory system:

        <types>
        <type>
            <name>user</name>
            <description>Contain information about the user's role, goals, responsibilities, and knowledge. Great user memories help you tailor your future behavior to the user's preferences and perspective. Your goal in reading and writing these memories is to build up an understanding of who the user is and how you can be most helpful to them specifically. For example, you should collaborate with a senior software engineer differently than a student who is coding for the very first time. Keep in mind, that the aim here is to be helpful to the user. Avoid writing memories about the user that could be viewed as a negative judgement or that are not relevant to the work you're trying to accomplish together.</description>
            <when_to_save>When you learn any details about the user's role, preferences, responsibilities, or knowledge</when_to_save>
            <how_to_use>When your work should be informed by the user's profile or perspective. For example, if the user is asking you to explain a part of the code, you should answer that question in a way that is tailored to the specific details that they will find most valuable or that helps them build their mental model in relation to domain knowledge they already have.</how_to_use>
            <examples>
            user: I'm a data scientist investigating what logging we have in place
            assistant: [saves user memory: user is a data scientist, currently focused on observability/logging]

            user: I've been writing Go for ten years but this is my first time touching the React side of this repo
            assistant: [saves user memory: deep Go expertise, new to React and this project's frontend — frame frontend explanations in terms of backend analogues]
            </examples>
        </type>
        <type>
            <name>feedback</name>
            <description>Guidance the user has given you about how to approach work — both what to avoid and what to keep doing. These are a very important type of memory to read and write as they allow you to remain coherent and responsive to the way you should approach work in the project. Record from failure AND success: if you only save corrections, you will avoid past mistakes but drift away from approaches the user has already validated, and may grow overly cautious.</description>
            <when_to_save>Any time the user corrects your approach ("no not that", "don't", "stop doing X") OR confirms a non-obvious approach worked ("yes exactly", "perfect, keep doing that", accepting an unusual choice without pushback). Corrections are easy to notice; confirmations are quieter — watch for them. In both cases, save what is applicable to future conversations, especially if surprising or not obvious from the code. Include *why* so you can judge edge cases later.</when_to_save>
            <how_to_use>Let these memories guide your behavior so that the user does not need to offer the same guidance twice.</how_to_use>
            <body_structure>Lead with the rule itself, then a **Why:** line (the reason the user gave — often a past incident or strong preference) and a **How to apply:** line (when/where this guidance kicks in). Knowing *why* lets you judge edge cases instead of blindly following the rule.</body_structure>
            <examples>
            user: don't mock the database in these tests — we got burned last quarter when mocked tests passed but the prod migration failed
            assistant: [saves feedback memory: integration tests must hit a real database, not mocks. Reason: prior incident where mock/prod divergence masked a broken migration]

            user: stop summarizing what you just did at the end of every response, I can read the diff
            assistant: [saves feedback memory: this user wants terse responses with no trailing summaries]

            user: yeah the single bundled PR was the right call here, splitting this one would've just been churn
            assistant: [saves feedback memory: for refactors in this area, user prefers one bundled PR over many small ones. Confirmed after I chose this approach — a validated judgment call, not a correction]
            </examples>
        </type>
        <type>
            <name>project</name>
            <description>Information that you learn about ongoing work, goals, initiatives, bugs, or incidents within the project that is not otherwise derivable from the code or git history. Project memories help you understand the broader context and motivation behind the work the user is doing within this working directory.</description>
            <when_to_save>When you learn who is doing what, why, or by when. These states change relatively quickly so try to keep your understanding of this up to date. Always convert relative dates in user messages to absolute dates when saving (e.g., "Thursday" → "2026-03-05"), so the memory remains interpretable after time passes.</when_to_save>
            <how_to_use>Use these memories to more fully understand the details and nuance behind the user's request and make better informed suggestions.</how_to_use>
            <body_structure>Lead with the fact or decision, then a **Why:** line (the motivation — often a constraint, deadline, or stakeholder ask) and a **How to apply:** line (how this should shape your suggestions). Project memories decay fast, so the why helps future-you judge whether the memory is still load-bearing.</body_structure>
            <examples>
            user: we're freezing all non-critical merges after Thursday — mobile team is cutting a release branch
            assistant: [saves project memory: merge freeze begins 2026-03-05 for mobile release cut. Flag any non-critical PR work scheduled after that date]

            user: the reason we're ripping out the old auth middleware is that legal flagged it for storing session tokens in a way that doesn't meet the new compliance requirements
            assistant: [saves project memory: auth middleware rewrite is driven by legal/compliance requirements around session token storage, not tech-debt cleanup — scope decisions should favor compliance over ergonomics]
            </examples>
        </type>
        <type>
            <name>reference</name>
            <description>Stores pointers to where information can be found in external systems. These memories allow you to remember where to look to find up-to-date information outside of the project directory.</description>
            <when_to_save>When you learn about resources in external systems and their purpose. For example, that bugs are tracked in a specific project in Linear or that feedback can be found in a specific Slack channel.</when_to_save>
            <how_to_use>When the user references an external system or information that may be in an external system.</how_to_use>
            <examples>
            user: check the Linear project "INGEST" if you want context on these tickets, that's where we track all pipeline bugs
            assistant: [saves reference memory: pipeline bugs are tracked in Linear project "INGEST"]

            user: the Grafana board at grafana.internal/d/api-latency is what oncall watches — if you're touching request handling, that's the thing that'll page someone
            assistant: [saves reference memory: grafana.internal/d/api-latency is the oncall latency dashboard — check it when editing request-path code]
            </examples>
        </type>
        </types>
        """
    }

    /// 生成 `## What NOT to save in memory` 节。
    func whatNotToSaveSection() -> String {
        """
        ## What NOT to save in memory

        - Code patterns, conventions, architecture, file paths, or project structure — these can be derived by reading the current project state.
        - Git history, recent changes, or who-changed-what — `git log` / `git blame` are authoritative.
        - Debugging solutions or fix recipes — the fix is in the code; the commit message has the context.
        - Anything already documented in CLAUDE.md files.
        - Ephemeral task details: in-progress work, temporary state, current conversation context.

        These exclusions apply even when the user explicitly asks you to save. If they ask you to save a PR list or activity summary, ask what was *surprising* or *non-obvious* about it — that is the part worth keeping.
        """
    }

    /// 拼接 typesSection + whatNotToSaveSection + howToSaveSection，生成完整的记忆类型指导块。
    func compose() -> String {
        [typesSection(), whatNotToSaveSection(), howToSaveSection()].joined(separator: "\n\n")
    }

    /// 生成 `## How to Save Memories` 节，描述两步保存流程。
    /// memoryDir 默认从 ConfigDirectoryManager 读取（允许测试注入）。
    func howToSaveSection(memoryDir: String? = nil) -> String {
        let dir = memoryDir ?? ConfigDirectoryManager.shared.memoryDir.path
        return """
        ## How to Save Memories

        Your persistent memory lives at `\(dir)/`.
        This directory already exists — write directly without checking for its existence.

        Saving a memory is a two-step process:

        **Step 1** — write the memory to its own topic file (e.g., `user_role.md`, `feedback_testing.md`):
        ```
        ---
        name: "Title of this memory"
        description: "One-line description for the MEMORY.md index"
        type: user | feedback | project | reference
        ---

        Body: the full memory content goes here.
        ```

        **Step 2** — add a one-line pointer to `MEMORY.md`:
        `- [Title](filename.md) — one-line hook under ~150 chars`

        Rules:
        - `MEMORY.md` is an index only — never write memory content directly into it.
        - `MEMORY.md` has no frontmatter.
        - Lines after \(MemoryIndexWriter.maxLines) in `MEMORY.md` will be truncated — keep entries concise.
        - Before writing a new memory, check if an existing file can be updated instead.
        """
    }
}
