//
//  Skill.swift
//  agentGui
//

import Foundation

/// A locally installed skill discovered from ~/.claude/skills/
struct Skill: Identifiable, Hashable {
    /// Directory name — used as stable identifier
    var id: String { directoryName }
    let directoryName: String
    /// Human-readable name from `name:` frontmatter key; falls back to directoryName
    let name: String
    /// Short description from `description:` frontmatter key
    let description: String
    /// URL to the skill directory
    let path: URL
    /// URL to the SKILL.md file inside the directory
    let contentURL: URL
}
