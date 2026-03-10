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

    // MARK: - State

    var availableSkills: [Skill] = []

    // MARK: - Private

    private var contentCache: [String: String] = [:]

    private let skillsDirectory: URL = {
        // URL.homeDirectory resolves to the sandbox container in sandboxed apps.
        // getpwuid gives the real system home directory (e.g. /Users/feint).
        let realHome: String
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            realHome = String(cString: dir)
        } else {
            realHome = NSHomeDirectory()
        }
        return URL(fileURLWithPath: realHome, isDirectory: true)
            .appending(path: ".claude/skills", directoryHint: .isDirectory)
    }()

    // MARK: - Load

    /// Scans the skills directory and populates `availableSkills`.
    func loadSkills() {
        let fm = FileManager.default
        print("[SkillService] skillsDirectory = \(skillsDirectory.path)")

        guard fm.fileExists(atPath: skillsDirectory.path) else {
            print("[SkillService] ❌ directory does not exist: \(skillsDirectory.path)")
            availableSkills = []
            return
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

                let (name, description) = parseFrontmatter(at: skillFile)
                let dirName = url.lastPathComponent
                print("[SkillService]   loaded skill: dir=\(dirName) name=\(name ?? "(nil)") desc=\(description?.prefix(60) ?? "(nil)")")
                return Skill(
                    directoryName: dirName,
                    name: name ?? dirName,
                    description: description ?? "",
                    path: url,
                    contentURL: skillFile
                )
            }
            availableSkills = loaded.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
            print("[SkillService] ✅ availableSkills(\(availableSkills.count)): \(availableSkills.map(\.name))")
        } catch {
            print("[SkillService] ❌ contentsOfDirectory error: \(error)")
            availableSkills = []
        }
    }

    // MARK: - Content

    /// Returns the full SKILL.md content for the skill matching `name` (by name or directoryName).
    /// Absolute-looking paths in the content (e.g. `/references/schemas.md`) that exist within
    /// the skill's directory are rewritten to their real absolute paths, and a directory context
    /// header is prepended so the agent always knows where bundled resources live.
    /// Result is cached after the first load.
    func readSkillContent(name: String) -> String? {
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

        guard let raw = try? String(contentsOf: skill.contentURL, encoding: .utf8) else {
            print("[SkillService]  read_skill '\(name)' — failed to read \(skill.contentURL.path)")
            return nil
        }

        let processed = resolveSkillPaths(in: raw, skillDirectory: skill.path)
        contentCache[key] = processed
        print("[SkillService] read_skill '\(name)' — loaded \(processed.count) chars from \(skill.contentURL.path)")
        return processed
    }

    /// Rewrites absolute-looking paths in `content` that resolve to real files/dirs within
    /// `skillDirectory`, and prepends a skill-directory context line for Claude to use.
    ///
    /// For example, `/references/schemas.md` becomes
    /// `/Users/feint/.claude/skills/skill-creator/references/schemas.md`
    /// when that file exists inside the skill directory.
    private static let skillPathRegex: NSRegularExpression = {
        // Matches a leading `/` followed by at least one path-safe character.
        // The negative lookbehind (?<![.\w]) prevents matching inside URLs (e.g. "://…")
        // or dotted identifiers.
        try! NSRegularExpression(pattern: #"(?<![.\w])(\/[A-Za-z0-9_.\-][A-Za-z0-9_.\-\/]*)"#)
    }()

    private func resolveSkillPaths(in content: String, skillDirectory: URL) -> String {
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

    /// Parses YAML frontmatter (between `---` markers) and extracts `name:` and `description:` values.
    /// Only the first frontmatter block is parsed. Multi-line values are not supported.
    private func parseFrontmatter(at url: URL) -> (name: String?, description: String?) {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
            print("[SkillService]   parseFrontmatter: failed to read \(url.path)")
            return (nil, nil)
        }

        let lines = raw.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else {
            print("[SkillService]   parseFrontmatter: no frontmatter in \(url.lastPathComponent)")
            return (nil, nil)
        }

        var name: String? = nil
        var description: String? = nil
        var descriptionLines: [String] = []
        var inFrontmatter = false
        var collectingDescription = false

        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if i == 0 { inFrontmatter = true; continue }
            if trimmed == "---" && inFrontmatter { break }
            guard inFrontmatter else { break }

            if collectingDescription {
                // Multi-line description: continuation lines start with whitespace
                if line.hasPrefix("  ") || line.hasPrefix("\t") {
                    descriptionLines.append(trimmed)
                    continue
                } else {
                    collectingDescription = false
                }
            }

            if trimmed.hasPrefix("name:") {
                let value = trimmed.dropFirst("name:".count).trimmingCharacters(in: .whitespaces)
                name = removeQuotes(value)
            } else if trimmed.hasPrefix("description:") {
                let value = trimmed.dropFirst("description:".count).trimmingCharacters(in: .whitespaces)
                if value.isEmpty {
                    collectingDescription = true
                } else {
                    descriptionLines = [removeQuotes(value)]
                    collectingDescription = true
                }
            }
        }

        description = descriptionLines.isEmpty ? nil : descriptionLines.joined(separator: " ")
        return (name, description)
    }

    private func removeQuotes(_ s: String) -> String {
        var s = s
        if (s.hasPrefix("\"") && s.hasSuffix("\"")) || (s.hasPrefix("'") && s.hasSuffix("'")) {
            s = String(s.dropFirst().dropLast())
        }
        return s
    }
}
