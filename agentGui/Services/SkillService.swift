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

        guard let content = try? String(contentsOf: skill.contentURL, encoding: .utf8) else {
            print("[SkillService]  read_skill '\(name)' — failed to read \(skill.contentURL.path)")
            return nil
        }
        contentCache[key] = content
        print("[SkillService] read_skill '\(name)' — loaded \(content.count) chars from \(skill.contentURL.path)")
        return content
    }

    /// Returns only the skills whose directoryName appears in `enabledNames`.
    func enabledSkills(enabledNames: [String]) -> [Skill] {
        guard !enabledNames.isEmpty else { return [] }
        return availableSkills.filter { enabledNames.contains($0.directoryName) }
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
