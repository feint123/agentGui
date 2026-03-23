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
        let filtered: [IndexedSlashItem]
        if normalizedQuery.isEmpty {
            filtered = allItems.enumerated().map(IndexedSlashItem.init)
        } else {
            filtered = allItems.enumerated().compactMap { entry in
                let indexedItem = IndexedSlashItem(entry)
                let item = indexedItem.item
                let matches = [item.title, item.subtitle]
                    .appending(contentsOf: item.aliases)
                    .contains { candidate in
                        candidate.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                            .contains(normalizedQuery)
                    }
                return matches ? indexedItem : nil
            }
        }

        return filtered.sorted(by: sort(lhs:rhs:)).map(\.item)
    }

    private func sort(lhs: IndexedSlashItem, rhs: IndexedSlashItem) -> Bool {
        let lhsItem = lhs.item
        let rhsItem = rhs.item

        if lhsItem.isEnabledByDefault != rhsItem.isEnabledByDefault {
            return lhsItem.isEnabledByDefault && !rhsItem.isEnabledByDefault
        }

        if lhsItem.kind != rhsItem.kind {
            return sortPriority(for: lhsItem.kind) < sortPriority(for: rhsItem.kind)
        }

        if lhsItem.kind == .agent {
            return lhs.originalIndex < rhs.originalIndex
        }

        let titleComparison = lhsItem.title.localizedCaseInsensitiveCompare(rhsItem.title)
        if titleComparison != .orderedSame {
            return titleComparison == .orderedAscending
        }

        return lhs.originalIndex < rhs.originalIndex
    }

    private func sortPriority(for kind: ChatSlashCommandKind) -> Int {
        switch kind {
        case .agent:
            return 0
        case .skill:
            return 1
        case .preset:
            return 2
        case .contextAction:
            return 3
        }
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

private struct IndexedSlashItem {
    let originalIndex: Int
    let item: ChatSlashCommandItem

    init(_ entry: EnumeratedSequence<[ChatSlashCommandItem]>.Element) {
        self.originalIndex = entry.offset
        self.item = entry.element
    }
}

private extension Array where Element == String {
    func appending(contentsOf values: [String]) -> [String] {
        var copy = self
        copy.append(contentsOf: values)
        return copy
    }
}