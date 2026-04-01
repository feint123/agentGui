//
//  SkillService.swift
//  agentGui
//

import Foundation
import Observation
import Darwin

/// Scans ~/.claude/skills/ for skill directories, parses YAML frontmatter,
/// and provides skill content to the agent on demand.
@Observable
@MainActor
final class SkillService {
    nonisolated private struct LoadedSkillContent: Sendable {
        let cacheKey: String
        let content: String
    }

    // MARK: - State

    var availableSkills: [Skill] = []

    // MARK: - Private

    private var contentCache: [String: String] = [:]

    private let skillsDirectory: URL
    private var workspaceURL: URL?

    init(skillsDirectory: URL? = nil, workspaceURL: URL? = nil) {
        self.skillsDirectory = skillsDirectory ?? Self.defaultSkillsDirectory()
        self.workspaceURL = workspaceURL
    }

    // MARK: - Load

    /// Scans all skill sources (user + project) and populates `availableSkills`.
    func loadSkills() async {
        let userDir = skillsDirectory
        let workspace = workspaceURL
        availableSkills = await Task.detached(priority: .userInitiated) { [userDir, workspace] in
            Self.loadAllSkills(userSkillsDir: userDir, workspaceURL: workspace)
        }.value
    }

    /// 使用新的 workspace 重新加载所有来源的技能。
    func loadSkills(workspaceURL: URL?) async {
        self.workspaceURL = workspaceURL
        let userDir = skillsDirectory
        availableSkills = await Task.detached(priority: .userInitiated) { [userDir, workspaceURL] in
            Self.loadAllSkills(userSkillsDir: userDir, workspaceURL: workspaceURL)
        }.value
    }

    // MARK: - Content

    /// Returns the full SKILL.md content for the skill matching `name` (by name or directoryName).
    /// Absolute-looking paths in the content (e.g. `/references/schemas.md`) that exist within
    /// the skill's directory are rewritten to their real absolute paths, and a directory context
    /// header is prepended so the agent always knows where bundled resources live.
    /// Result is cached after the first load.
    func readSkillContent(name: String) async -> String? {
        // Match by display name first, then by directoryName
        guard let skill = availableSkills.first(where: { $0.name == name || $0.directoryName == name }) else {
            print("[SkillService]  read_skill: '\(name)' not found. available=\(availableSkills.map(\.name))")
            return nil
        }
        let key = skill.directoryName
        if let cached = contentCache[key] {
            print("[SkillService] read_skill '\(name)' — returned from cache (\(cached.count) chars)")
            return cached
        }

        let loaded = await Task.detached(priority: .utility) {
            Self.loadSkillContent(skill)
        }.value

        guard let loaded else {
            print("[SkillService]  read_skill '\(name)' — failed to read \(skill.contentURL.path)")
            return nil
        }

        contentCache[loaded.cacheKey] = loaded.content
        print("[SkillService] read_skill '\(name)' — loaded \(loaded.content.count) chars from \(skill.contentURL.path)")
        return loaded.content
    }

    /// Rewrites absolute-looking paths in `content` that resolve to real files/dirs within
    /// `skillDirectory`, and prepends a skill-directory context line for Claude to use.
    ///
    /// For example, `/references/schemas.md` becomes
    /// `/Users/feint/.claude/skills/skill-creator/references/schemas.md`
    /// when that file exists inside the skill directory.
    nonisolated private static let skillPathRegex: NSRegularExpression = {
        // Matches a leading `/` followed by at least one path-safe character.
        // The negative lookbehind (?<![.\w]) prevents matching inside URLs (e.g. "://…")
        // or dotted identifiers.
        try! NSRegularExpression(pattern: #"(?<![.\w])(\/[A-Za-z0-9_.\-][A-Za-z0-9_.\-\/]*)"#)
    }()

    nonisolated private static func resolveSkillPaths(in content: String, skillDirectory: URL) -> String {
        let fm = FileManager.default
        let skillDirPath = skillDirectory.path

        // System-path prefixes that should never be rewritten (already absolute system paths
        // or paths that already start with the skill directory).
        let systemPrefixes = [
            "/Users/", "/home/", "/etc/", "/var/", "/tmp/",
            "/usr/", "/opt/", "/Library/", "/System/", "/Applications/",
            skillDirPath
        ]

        let mutable = NSMutableString(string: content)
        let fullRange = NSRange(location: 0, length: mutable.length)
        let matches = Self.skillPathRegex.matches(in: content, range: fullRange)

        // Walk matches in reverse so that earlier-in-string ranges remain valid after
        // each replacement (NSRange offsets are UTF-16 based and shift only for positions
        // after the replaced range).
        for match in matches.reversed() {
            let nsRange = match.range(at: 1)
            guard nsRange.location != NSNotFound else { continue }
            let candidate = mutable.substring(with: nsRange)

            // Skip system/already-absolute paths
            if systemPrefixes.contains(where: { candidate.hasPrefix($0) }) { continue }

            // Only rewrite if the file/directory actually exists inside the skill directory
            let resolved = skillDirPath + candidate
            guard fm.fileExists(atPath: resolved) else { continue }

            mutable.replaceCharacters(in: nsRange, with: resolved)
            print("[SkillService]   path resolved: \(candidate) → \(resolved)")
        }

        // Prepend a context note with the skill directory so the agent can resolve any
        // relative references (e.g. `references/schemas.md`) that weren't caught above.
        let header = "<!-- skill_directory: \(skillDirPath) -->\n"
        return header + (mutable as String)
    }

    /// Returns only the skills whose directoryName appears in `enabledNames`.
    func enabledSkills(enabledNames: [String]) -> [Skill] {
        guard !enabledNames.isEmpty else { return [] }
        return availableSkills.filter { enabledNames.contains($0.directoryName) }
    }

    /// Returns the first skill matching either the display name or directory name.
    func skill(namedOrDirectoryName name: String) -> Skill? {
        availableSkills.first { $0.name == name || $0.directoryName == name }
    }

    /// Clears the content cache (used when skills are refreshed).
    func clearCache() {
        contentCache.removeAll()
    }

    // MARK: - Frontmatter Parsing

    /// SkillService 内部使用的 frontmatter 解析结果，包含所有 S-A1 新字段。
    private struct SkillFrontmatterResult {
        var name: String?
        var description: String?
        var whenToUse: String?
        var argumentHint: String?
        var argumentNames: [String] = []
        var allowedTools: [String] = []
        var model: String?
        var effort: EffortLevel?
        var executionContext: SkillExecutionContext = .inline
        var agent: String?
        var userInvocable: Bool = true
        var disableModelInvocation: Bool = false
        var version: String?
        var paths: [String]?
    }

    /// Parses YAML frontmatter (between `---` markers) and extracts all S-A1 manifest fields.
    /// Only the first frontmatter block is parsed. Missing fields fall back to safe defaults.
    nonisolated private static func parseFrontmatter(at url: URL) -> SkillFrontmatterResult {
        var result = SkillFrontmatterResult()

        guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
            print("[SkillService]   parseFrontmatter: failed to read \(url.path)")
            return result
        }

        let lines = raw.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else {
            print("[SkillService]   parseFrontmatter: no frontmatter in \(url.lastPathComponent)")
            return result
        }

        var inFrontmatter = false
        var collectingField: String? = nil
        var collectedLines: [String] = []

        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if i == 0 { inFrontmatter = true; continue }
            if trimmed == "---" && inFrontmatter {
                flushCollectedLines(&result, field: collectingField, lines: collectedLines)
                break
            }
            guard inFrontmatter else { break }

            // 续行（以两个空格或 Tab 开头的列表项）
            if let field = collectingField,
               (line.hasPrefix("  ") || line.hasPrefix("\t")) {
                let item = trimmed.hasPrefix("- ") ? String(trimmed.dropFirst(2)) : trimmed
                let cleaned = removeQuotes(item)
                if !cleaned.isEmpty { collectedLines.append(cleaned) }
                continue
            } else if collectingField != nil {
                flushCollectedLines(&result, field: collectingField, lines: collectedLines)
                collectingField = nil
                collectedLines = []
            }

            guard let colonIdx = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[..<colonIdx]).trimmingCharacters(in: .whitespaces)
            let rawValue = String(trimmed[trimmed.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)

            switch key {
            case "name":
                result.name = removeQuotes(rawValue)

            case "description":
                if rawValue.isEmpty {
                    collectingField = "description"
                    collectedLines = []
                } else {
                    result.description = removeQuotes(rawValue)
                }

            case "when_to_use":
                result.whenToUse = removeQuotes(rawValue).nonEmptyOrNil

            case "argument-hint":
                result.argumentHint = removeQuotes(rawValue).nonEmptyOrNil

            case "arguments":
                if rawValue.hasPrefix("[") {
                    result.argumentNames = parseInlineList(rawValue)
                } else if rawValue.isEmpty {
                    collectingField = "arguments"
                    collectedLines = []
                } else {
                    result.argumentNames = [removeQuotes(rawValue)]
                }

            case "allowed-tools":
                if rawValue.hasPrefix("[") {
                    result.allowedTools = parseInlineList(rawValue)
                } else if rawValue.isEmpty {
                    collectingField = "allowed-tools"
                    collectedLines = []
                } else {
                    result.allowedTools = [removeQuotes(rawValue)]
                }

            case "model":
                let m = removeQuotes(rawValue)
                result.model = m == "inherit" ? nil : m.nonEmptyOrNil

            case "effort":
                result.effort = EffortLevel(rawValue: removeQuotes(rawValue).lowercased())
                if result.effort == nil && !rawValue.isEmpty {
                    print("[SkillService]   parseFrontmatter: invalid effort '\(rawValue)' in \(url.lastPathComponent)")
                }

            case "context":
                result.executionContext = SkillExecutionContext(rawValue: removeQuotes(rawValue)) ?? .inline

            case "agent":
                result.agent = removeQuotes(rawValue).nonEmptyOrNil

            case "user-invocable":
                result.userInvocable = parseBool(rawValue, default: true)

            case "disable-model-invocation":
                result.disableModelInvocation = parseBool(rawValue, default: false)

            case "version":
                result.version = removeQuotes(rawValue).nonEmptyOrNil

            case "paths":
                if rawValue.hasPrefix("[") {
                    result.paths = parseInlineList(rawValue).nonEmptyOrNil
                } else if rawValue.isEmpty {
                    collectingField = "paths"
                    collectedLines = []
                } else {
                    result.paths = [removeQuotes(rawValue)]
                }

            default:
                break
            }
        }

        return result
    }

    nonisolated private static func flushCollectedLines(
        _ result: inout SkillFrontmatterResult,
        field: String?,
        lines: [String]
    ) {
        guard let field, !lines.isEmpty else { return }
        switch field {
        case "description":   result.description = lines.joined(separator: " ")
        case "arguments":     result.argumentNames = lines
        case "allowed-tools": result.allowedTools = lines
        case "paths":         result.paths = lines.nonEmptyOrNil
        default: break
        }
    }

    /// Parses a YAML inline list like `[a, b, c]`.
    nonisolated private static func parseInlineList(_ raw: String) -> [String] {
        let stripped = raw.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return stripped
            .components(separatedBy: ",")
            .map { removeQuotes($0.trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.isEmpty }
    }

    /// Parses a YAML boolean value (`true`/`false`/`yes`/`no`).
    nonisolated private static func parseBool(_ raw: String, default defaultValue: Bool) -> Bool {
        switch raw.lowercased() {
        case "true", "yes", "1":  return true
        case "false", "no", "0":  return false
        default:                   return defaultValue
        }
    }

    nonisolated private static func removeQuotes(_ s: String) -> String {
        var s = s
        if (s.hasPrefix("\"") && s.hasSuffix("\"")) || (s.hasPrefix("'") && s.hasSuffix("'")) {
            s = String(s.dropFirst().dropLast())
        }
        return s
    }

    nonisolated private static func defaultSkillsDirectory() -> URL {
        let realHome: String
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            realHome = String(cString: dir)
        } else {
            realHome = NSHomeDirectory()
        }
        return URL(fileURLWithPath: realHome, isDirectory: true)
            .appending(path: ".claude/skills", directoryHint: .isDirectory)
    }

    /// 多源加载入口：user + project（deep-first）→ 合并去重 → 排序。
    nonisolated private static func loadAllSkills(
        userSkillsDir: URL,
        workspaceURL: URL?
    ) -> [Skill] {
        // 1. User source
        let userSkills = scanSkills(in: userSkillsDir, source: .user)

        // 2. Project sources（workspace 向上遍历）
        var projectSkills: [Skill] = []
        if let workspace = workspaceURL {
            let projectDirs = projectSkillDirs(startingAt: workspace)
            for dir in projectDirs {
                let skills = scanSkills(in: dir, source: .project)
                projectSkills.append(contentsOf: skills)
            }
        }

        // 3. 合并去重（user 优先于 project）
        let merged = mergeAndDeduplicate(userSkills + projectSkills)
        return merged.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    /// 合并多个来源的 Skill 列表，通过 realpath 过滤 symlink 重复。
    /// 策略：first-wins by canonical path（入参顺序决定优先级）。
    nonisolated internal static func mergeAndDeduplicate(_ allSkills: [Skill]) -> [Skill] {
        var seenRealPaths: Set<String> = []
        return allSkills.filter { skill in
            let resolved = skill.contentURL.resolvingSymlinksInPath().path
            if seenRealPaths.contains(resolved) {
                return false
            }
            seenRealPaths.insert(resolved)
            return true
        }
    }

    /// 从 `startURL` 向上遍历，收集沿途存在的 `.claude/skills/` 目录路径列表。
    ///
    /// 停止条件：到达 `home`、到达 git root 后处理该层、到达文件系统根。
    /// 返回顺序：deep-first（最接近 startURL 的目录在最前）。
    nonisolated internal static func projectSkillDirs(
        startingAt startURL: URL,
        home: URL? = nil
    ) -> [URL] {
        let fm = FileManager.default
        let homeURL = (home ?? homeDirectory()).standardized
        let stopAtGit = gitRoot(for: startURL)
        var current = startURL.standardized
        var dirs: [URL] = []

        while true {
            // HOME 本身不遍历（其 user skills 由独立路径负责）
            if current.path == homeURL.path { break }

            let claudeSkills = current.appending(path: ".claude/skills")
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: claudeSkills.path, isDirectory: &isDir), isDir.boolValue {
                dirs.append(claudeSkills)
            }

            // 处理完 git root 层后停止——防止 repo 外的父目录渗透
            if let gitRoot = stopAtGit, current.path == gitRoot.path { break }

            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }  // 文件系统根
            current = parent
        }

        return dirs
    }

    /// 从 `startURL` 向上查找最近的含 `.git` 目录/文件的祖先目录。
    nonisolated internal static func gitRoot(for startURL: URL) -> URL? {
        let fm = FileManager.default
        var current = startURL.standardized

        while true {
            let gitPath = current.appending(path: ".git")
            if fm.fileExists(atPath: gitPath.path) {
                return current
            }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path {
                // 到达文件系统根
                return nil
            }
            current = parent
        }
    }

    /// 返回当前进程运行的真实 HOME 目录（优先使用 getpwuid 以避免沙箱偏差）。
    nonisolated private static func homeDirectory() -> URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }

    nonisolated internal static func scanSkills(in skillsDirectory: URL, source: SkillSource = .user) -> [Skill] {
        let fm = FileManager.default
        print("[SkillService] skillsDirectory = \(skillsDirectory.path) source=\(source)")

        guard fm.fileExists(atPath: skillsDirectory.path) else {
            print("[SkillService] ❌ directory does not exist: \(skillsDirectory.path)")
            return []
        }
        print("[SkillService] ✅ directory exists")

        do {
            let contents = try fm.contentsOfDirectory(
                at: skillsDirectory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
            print("[SkillService] entries found: \(contents.map(\.lastPathComponent))")

            let loaded: [Skill] = contents.compactMap { url in
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
                    print("[SkillService]   skip (not a directory): \(url.lastPathComponent)")
                    return nil
                }
                let skillFile = url.appending(path: "SKILL.md")
                guard fm.fileExists(atPath: skillFile.path) else {
                    print("[SkillService]   skip (no SKILL.md): \(url.lastPathComponent)")
                    return nil
                }

                let fmResult = parseFrontmatter(at: skillFile)
                let dirName = url.lastPathComponent

                // 检测参考文件（hasReferenceFiles）
                let otherFiles = (try? fm.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                ))?.filter { $0.lastPathComponent != "SKILL.md" } ?? []
                let hasReferenceFiles = !otherFiles.isEmpty

                print("[SkillService]   loaded skill: dir=\(dirName) name=\(fmResult.name ?? "(nil)") desc=\(fmResult.description?.prefix(60) ?? "(nil)")")
                return Skill(
                    directoryName: dirName,
                    name: fmResult.name ?? dirName,
                    description: fmResult.description ?? "",
                    path: url,
                    contentURL: skillFile,
                    whenToUse: fmResult.whenToUse,
                    argumentHint: fmResult.argumentHint,
                    argumentNames: fmResult.argumentNames,
                    allowedTools: fmResult.allowedTools,
                    model: fmResult.model,
                    effort: fmResult.effort,
                    executionContext: fmResult.executionContext,
                    agent: fmResult.agent,
                    userInvocable: fmResult.userInvocable,
                    disableModelInvocation: fmResult.disableModelInvocation,
                    version: fmResult.version,
                    paths: fmResult.paths,
                    hasReferenceFiles: hasReferenceFiles,
                    loadedFrom: source
                )
            }

            let sorted = loaded.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
            print("[SkillService] ✅ availableSkills(\(sorted.count)): \(sorted.map(\.name))")
            return sorted
        } catch {
            print("[SkillService] ❌ contentsOfDirectory error: \(error)")
            return []
        }
    }

    nonisolated private static func loadSkillContent(_ skill: Skill) -> LoadedSkillContent? {
        guard let raw = try? String(contentsOf: skill.contentURL, encoding: .utf8) else {
            return nil
        }

        return LoadedSkillContent(
            cacheKey: skill.directoryName,
            content: resolveSkillPaths(in: raw, skillDirectory: skill.path)
        )
    }
}

// MARK: - Frontmatter helpers

private extension String {
    /// Returns nil if the string is empty, otherwise self.
    var nonEmptyOrNil: String? { isEmpty ? nil : self }
}

private extension Array {
    /// Returns nil if the array is empty, otherwise self.
    var nonEmptyOrNil: [Element]? { isEmpty ? nil : self }
}
