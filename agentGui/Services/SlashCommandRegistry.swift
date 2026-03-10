import Foundation

protocol ChatSlashCommandProvider {
    func items() -> [ChatSlashCommandItem]
}

struct ChatSlashCommandRegistry {
    let providers: [any ChatSlashCommandProvider]

    init(providers: [any ChatSlashCommandProvider]) {
        self.providers = providers
    }

    func items(matching query: String) -> [ChatSlashCommandItem] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)

        let allItems = providers.flatMap { $0.items() }
        let filtered: [ChatSlashCommandItem]
        if normalizedQuery.isEmpty {
            filtered = allItems
        } else {
            filtered = allItems.filter { item in
                [item.title, item.subtitle]
                    .appending(contentsOf: item.aliases)
                    .contains { candidate in
                        candidate.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                            .contains(normalizedQuery)
                    }
            }
        }

        return filtered.sorted(by: sort(lhs:rhs:))
    }

    private func sort(lhs: ChatSlashCommandItem, rhs: ChatSlashCommandItem) -> Bool {
        if lhs.isEnabledByDefault != rhs.isEnabledByDefault {
            return lhs.isEnabledByDefault && !rhs.isEnabledByDefault
        }

        if lhs.kind != rhs.kind {
            return lhs.kind.rawValue < rhs.kind.rawValue
        }

        return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
    }
}

struct SkillChatSlashCommandProvider: ChatSlashCommandProvider {
    let skills: [Skill]
    let enabledSkillNames: [String]

    func items() -> [ChatSlashCommandItem] {
        skills.map { skill in
            ChatSlashCommandItem(
                id: "skill:\(skill.directoryName)",
                kind: .skill,
                title: skill.name,
                subtitle: skill.description,
                aliases: [skill.directoryName],
                badge: "Skill",
                isEnabledByDefault: enabledSkillNames.contains(skill.directoryName),
                payload: .skill(directoryName: skill.directoryName)
            )
        }
    }
}

private extension Array where Element == String {
    func appending(contentsOf values: [String]) -> [String] {
        var copy = self
        copy.append(contentsOf: values)
        return copy
    }
}