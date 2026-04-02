//
//  BuiltInSkillRegistry.swift
//  agentGui
//

import Foundation

// MARK: - BuiltInSkillDefinition

/// Programmatic definition for a skill shipped with the app binary.
/// Mirrors `BundledSkillDefinition` in Claude Code `src/skills/bundledSkills.ts`.
struct BuiltInSkillDefinition: Sendable {
    let name: String
    let description: String

    // 执行控制（全部可选，对照 S-A1 Skill 字段）
    let whenToUse: String?
    let argumentHint: String?
    let argumentNames: [String]
    let allowedTools: [String]
    let model: String?
    let effort: EffortLevel?
    let executionContext: SkillExecutionContext
    let agent: String?
    let userInvocable: Bool
    let disableModelInvocation: Bool
    let version: String?

    /// 条件启用：返回 false 时，`allSkills()` 不包含该技能。nil 表示始终启用。
    let isEnabled: (@Sendable () -> Bool)?

    /// 技能内容提供器（返回原始 prompt 模板，含 $ARGUMENTS 等占位符）。
    let getPromptContent: @Sendable () async -> String

    init(
        name: String,
        description: String,
        whenToUse: String? = nil,
        argumentHint: String? = nil,
        argumentNames: [String] = [],
        allowedTools: [String] = [],
        model: String? = nil,
        effort: EffortLevel? = nil,
        executionContext: SkillExecutionContext = .inline,
        agent: String? = nil,
        userInvocable: Bool = true,
        disableModelInvocation: Bool = false,
        version: String? = nil,
        isEnabled: (@Sendable () -> Bool)? = nil,
        getPromptContent: @escaping @Sendable () async -> String
    ) {
        self.name = name
        self.description = description
        self.whenToUse = whenToUse
        self.argumentHint = argumentHint
        self.argumentNames = argumentNames
        self.allowedTools = allowedTools
        self.model = model
        self.effort = effort
        self.executionContext = executionContext
        self.agent = agent
        self.userInvocable = userInvocable
        self.disableModelInvocation = disableModelInvocation
        self.version = version
        self.isEnabled = isEnabled
        self.getPromptContent = getPromptContent
    }
}

// MARK: - BuiltInSkillRegistry

/// Registry for skills shipped with the app binary.
///
/// Write pattern: `register()` is called only at app startup (serial),
/// before any concurrent reads. `@unchecked Sendable` is therefore safe
/// for the stored dictionary.
///
/// Usage:
/// ```swift
/// // At app startup:
/// BuiltInSkillRegistry.shared.register(mySkillDefinition)
///
/// // In SkillService:
/// let bundled = BuiltInSkillRegistry.shared.allSkills()
/// ```
final class BuiltInSkillRegistry: @unchecked Sendable {

    // MARK: - Shared Instance

    static let shared = BuiltInSkillRegistry()

    // MARK: - Private Storage

    /// Keyed by `name` for O(1) lookup in `promptContent()`.
    private var definitions: [String: BuiltInSkillDefinition] = [:]

    // MARK: - Init

    init() {}

    // MARK: - Registration

    /// Registers a built-in skill definition.
    /// If a definition with the same `name` already exists, it is replaced.
    /// Call only at app startup (serial context) before any async access.
    func register(_ definition: BuiltInSkillDefinition) {
        definitions[definition.name] = definition
    }

    // MARK: - Query

    /// Returns all enabled built-in skills as `Skill` value types.
    /// Skills with `isEnabled` returning `false` are excluded.
    func allSkills() -> [Skill] {
        definitions.values
            .filter { $0.isEnabled?() ?? true }
            .map(Self.makeSkill(from:))
            .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    /// Returns the raw prompt template for a registered skill, or nil if not found.
    func promptContent(skillName: String) async -> String? {
        guard let def = definitions[skillName] else { return nil }
        return await def.getPromptContent()
    }

    // MARK: - Testing Support

    /// Removes all registered definitions. Only call from test tearDown.
    func clearForTesting() {
        definitions.removeAll()
    }

    // MARK: - Private Helpers

    /// Maps a `BuiltInSkillDefinition` to a `Skill` value type.
    /// Uses a synthetic non-existent file URL as placeholder for `contentURL`;
    /// the real content is always fetched via `promptContent(skillName:)`.
    private static func makeSkill(from def: BuiltInSkillDefinition) -> Skill {
        // Synthetic paths: /bundled/<name>/ won't exist on any real macOS system,
        // so mergeAndDeduplicate won't confuse them with disk-based skills.
        let syntheticDir = URL(fileURLWithPath: "/bundled/\(def.name)", isDirectory: true)
        let syntheticContent = syntheticDir.appending(path: "SKILL.md")

        return Skill(
            directoryName: def.name,
            name: def.name,
            description: def.description,
            path: syntheticDir,
            contentURL: syntheticContent,
            whenToUse: def.whenToUse,
            argumentHint: def.argumentHint,
            argumentNames: def.argumentNames,
            allowedTools: def.allowedTools,
            model: def.model,
            effort: def.effort,
            executionContext: def.executionContext,
            agent: def.agent,
            userInvocable: def.userInvocable,
            disableModelInvocation: def.disableModelInvocation,
            version: def.version,
            paths: nil,
            hasReferenceFiles: false,
            loadedFrom: .bundled
        )
    }
}
