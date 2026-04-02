//
//  ClaudeService+Prompting.swift
//  agentGui
//

import Foundation

struct ExplicitlyActivatedSkill: Hashable {
    let skill: Skill
    let content: String
}

struct TurnSkillContext: Hashable {
    let effectiveSkills: [Skill]
    let explicitlyActivatedSkills: [ExplicitlyActivatedSkill]
}

struct SystemPromptRuntimeContext: Equatable {
    let currentDateTimeText: String
    let timezoneIdentifier: String
    let localeIdentifier: String
    let operatingSystemText: String
    let hostName: String
    let workingDirectory: String
    let workingDirectorySource: String
    let proxySummary: String?

    static func live(
        workingDirectory: String,
        settings: AppSettings,
        session: Session?
    ) -> SystemPromptRuntimeContext {
        let now = Date()
        let timezone = TimeZone.current
        let locale = Locale.current
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = timezone
        formatter.formatOptions = [.withInternetDateTime, .withColonSeparatorInTimeZone]

        let resolvedWorkingDirectory = workingDirectory.isEmpty
            ? FileManager.default.homeDirectoryForCurrentUser.path
            : workingDirectory

        let workingDirectorySource: String
        if let session, !session.workingDirectory.isEmpty {
            workingDirectorySource = "session-bound working directory"
        } else if !settings.workingDirectory.isEmpty {
            workingDirectorySource = "global default working directory"
        } else {
            workingDirectorySource = "home directory fallback"
        }

        let proxySummary: String?
        if settings.proxyConfiguration.isEnabled,
           let proxyURL = settings.proxyConfiguration.normalizedProxyURL {
            let bypass = settings.proxyConfiguration.bypassList.isEmpty
                ? "none"
                : settings.proxyConfiguration.bypassList.joined(separator: ", ")
            proxySummary = "enabled via \(proxyURL); bypass: \(bypass)"
        } else {
            proxySummary = nil
        }

        return SystemPromptRuntimeContext(
            currentDateTimeText: formatter.string(from: now),
            timezoneIdentifier: timezone.identifier,
            localeIdentifier: locale.identifier,
            operatingSystemText: ProcessInfo.processInfo.operatingSystemVersionString,
            hostName: ProcessInfo.processInfo.hostName,
            workingDirectory: resolvedWorkingDirectory,
            workingDirectorySource: workingDirectorySource,
            proxySummary: proxySummary
        )
    }

    var promptSection: String {
        var lines = [
            "## Runtime Environment",
            "- Current date/time: \(currentDateTimeText)",
            "- Time zone: \(timezoneIdentifier)",
            "- Locale: \(localeIdentifier)",
            "- Operating system: \(operatingSystemText)",
            "- Host: \(hostName)",
            "- Working directory: \(workingDirectory) (source: \(workingDirectorySource))",
            "- Reality constraints: You are running inside a macOS app. Use the actual current date, OS, locale, and working directory above when reasoning about commands, files, timestamps, or environment-sensitive behavior. Do not assume a different platform or stale date."
        ]

        if let proxySummary {
            lines.append("- Network proxy: \(proxySummary)")
        }

        return lines.joined(separator: "\n")
    }
}

extension ClaudeService {

    // MARK: - System Prompt Builder

    func makeSystemPromptForTests(
        skills: [Skill],
        explicitlyActivatedSkills: [ExplicitlyActivatedSkill] = [],
        workingDirectory: String,
        settings: AppSettings,
        session: Session?,
        runtimeContextOverride: SystemPromptRuntimeContext? = nil
    ) -> String {
        buildSystemPrompt(
            skills: skills,
            explicitlyActivatedSkills: explicitlyActivatedSkills,
            workingDirectory: workingDirectory,
            settings: settings,
            sessionOverride: session,
            runtimeContextOverride: runtimeContextOverride
        )
    }

    func resolveTurnSkillContextForTests(
        enabledSkillNames: [String],
        directives: [ChatInputDirective]
    ) async throws -> TurnSkillContext {
        try await resolveTurnSkillContext(enabledSkillNames: enabledSkillNames, directives: directives)
    }

    func resolveTurnSkillContext(
        enabledSkillNames: [String],
        directives: [ChatInputDirective]
    ) async throws -> TurnSkillContext {
        let enabledSkills = skillService?.enabledSkills(enabledNames: enabledSkillNames) ?? []
        var effectiveSkillsByDirectory = Dictionary(uniqueKeysWithValues: enabledSkills.map { ($0.directoryName, $0) })
        var explicitlyActivatedSkills: [ExplicitlyActivatedSkill] = []

        for directive in directives {
            switch directive {
            case .skill(let directiveSkill):
                guard let skill = skillService?.skill(namedOrDirectoryName: directiveSkill.directoryName)
                    ?? skillService?.skill(namedOrDirectoryName: directiveSkill.displayName) else {
                    throw ClaudeError.missingSkill(directiveSkill.displayName)
                }
                guard let content = await skillService?.readSkillContent(name: skill.directoryName), !content.isEmpty else {
                    throw ClaudeError.unreadableSkill(skill.name)
                }

                effectiveSkillsByDirectory[skill.directoryName] = skill
                if explicitlyActivatedSkills.contains(where: { $0.skill.directoryName == skill.directoryName }) == false {
                    explicitlyActivatedSkills.append(ExplicitlyActivatedSkill(skill: skill, content: content))
                }
            }
        }

        let effectiveSkills = effectiveSkillsByDirectory.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        return TurnSkillContext(
            effectiveSkills: effectiveSkills,
            explicitlyActivatedSkills: explicitlyActivatedSkills
        )
    }

    func buildSystemPrompt(
        skills: [Skill],
        explicitlyActivatedSkills: [ExplicitlyActivatedSkill] = [],
        workingDirectory: String,
        settings: AppSettings,
        sessionOverride: Session? = nil,
        runtimeContextOverride: SystemPromptRuntimeContext? = nil
    ) -> String {
        var parts: [String] = []
        let runtimeContext = runtimeContextOverride
            ?? SystemPromptRuntimeContext.live(
                workingDirectory: workingDirectory,
                settings: settings,
                session: sessionOverride
            )

        parts.append(runtimeContext.promptSection)

        if !skills.isEmpty {
            let renderer = SkillCatalogPromptRenderer()
            let listing = renderer.renderSkillListing(skills)
            let section = [
                "## Available Skills",
                "Use the `skill_invoke` tool to run a skill, or the `read_skill` tool to inspect its full instructions.",
                "",
                listing
            ].joined(separator: "\n")
            parts.append(section)
        }

        if !explicitlyActivatedSkills.isEmpty {
            var lines = [
                "## Explicitly Activated Skills For This Turn",
                "The user explicitly activated these skills for this request. Treat them as active even if they are not globally enabled.",
                ""
            ]
            for activation in explicitlyActivatedSkills {
                lines.append("### \(activation.skill.name)")
                lines.append("Source: slash command")
                lines.append(activation.content)
                lines.append("")
            }
            parts.append(lines.joined(separator: "\n"))
        }

        parts.append("""
        ## Subagent Orchestration

        You have access to specialized subagents via the `run_subagent` tool. Follow these rules strictly:

        **Use `explore` FIRST whenever the task involves:**
        - Researching a topic, technology, product, or capability ("explore X", "research Y", "what can Z do", "Z 的能力")
        - Writing a report, analysis, comparison, or summary that requires gathering information
        - Finding documentation, APIs, changelogs, news, or any external reference
        - Answering factual questions about things that may have changed since your training cutoff

        **Workflow for research/report tasks (MANDATORY):**
        1. Call `run_subagent` with `agent_name: "explore"` to gather all needed information.
        2. Wait for the explore result.
        3. Synthesize the findings into the final response for the user.
        Do NOT attempt to answer research questions from memory alone when `explore` can gather live, accurate data.

        **Other delegation rules:**
        - Use `worker` for implementing or modifying files and for targeted verification work that is part of the implementation step.
        - Use `verifier` when you want an evidence review, frontier ranking, or a final quality gate before finishing.
        - Prefer direct execution for simple edits; delegate only when the task benefits from a focused subagent loop.
        """)

        parts.append("""
        ## Planning Protocol

        For **complex tasks** — defined as tasks requiring 3+ distinct steps, touching multiple \
        files or systems, or combining research with implementation — follow this workflow:

        ### 1. PLAN
        Call `create_execution_plan` at the very start to produce a structured plan artifact.
        - Break the work into 5–15 concrete, verb-first steps.
        - List key assumptions and success criteria.
                - For very large or ambiguous tasks, use `run_subagent` with `agent_name: "explore"` first to gather the missing context before creating the plan.

        ### 2. EXECUTE
        Work through the plan steps in order.
        - Keep `update_todo_list` in sync: mark steps `in_progress` when started, `done` when complete.
        - If an assumption proves wrong, note it and adapt — do not silently abandon the plan.

        ### 3. VERIFY
        The host runtime tracks verification frontier state and can block unsafe completion.
        - You are responsible for actively closing high-impact verification gaps before finishing.
        - When the remaining uncertainty is about whether claims are actually supported, call `run_subagent` with `agent_name: "verifier"`.
        - You may call `verify_completion` when you want to preserve a structured record of what was tested, what was not verified, and your overall conclusion.
        - Do NOT treat `verify_completion` as proof of completion.
        - Do NOT claim commands, builds, tests, or runtime checks that were not actually observed.
        - Missing or unsupported execution claims can reopen execution or trigger reflection.

        ### 4. SUMMARIZE
        End with a concise summary of what was done, what changed, and any recommended follow-up.

        **Simple tasks** (e.g. single-file edits, direct Q&A, quick lookups) do NOT need a plan. \
        Use your judgment — the goal is clarity and accountability, not ceremony.
        """)

        // Memory type guidance（对齐 Claude Code memoryTypes.ts）
        parts.append("## Memory System\n\n\(MemoryTypeGuidanceComposer().compose())")

        return parts.joined(separator: "\n\n")
    }

    /// 生成完整的 Memory System prompt 节（pure static，便于测试直接验证内容）。
    nonisolated static func memoryGuidanceSection() -> String {
        "## Memory System\n\n\(MemoryTypeGuidanceComposer().compose())"
    }

    /// 如果 MEMORY.md 有内容，生成 `## Your Memory Index` 节，否则返回空字符串。
    /// 调用方负责提供正确的 content（通过 MemoryIndexReader 读取）。
    nonisolated static func memoryIndexSection(content: String) -> String {
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        return """
        ## Your Memory Index

        The following is your current `MEMORY.md` index. Use it to discover which topic \
        files are available — read them with the file tools when you need the full content.

        \(content)
        """
    }
}