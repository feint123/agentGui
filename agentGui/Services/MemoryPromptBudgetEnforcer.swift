import Foundation

struct MemoryPromptBudgetEnforcer {
    struct Result: Equatable, Sendable {
        var renderedPrompt: String
        var trimmedCharCount: Int
        var postEnforcementPromptChars: Int
        var trimmedSectionIDs: [String]
        var totalPromptChars: Int
    }

    func enforce(sections: [MemoryPromptSection], budget: Int) -> Result {
        let fullPrompt = sections.map(\.text).joined(separator: "\n\n")
        guard budget > 0, fullPrompt.count > budget else {
            return Result(
                renderedPrompt: fullPrompt,
                trimmedCharCount: 0,
                postEnforcementPromptChars: fullPrompt.count,
                trimmedSectionIDs: [],
                totalPromptChars: fullPrompt.count
            )
        }

        var keptSections: [String] = []
        var trimmedSectionIDs: [String] = []
        var currentCount = 0

        for (index, section) in sections.enumerated() {
            let separatorCount = keptSections.isEmpty ? 0 : 2
            let fullSectionCost = separatorCount + section.text.count
            if currentCount + fullSectionCost <= budget {
                keptSections.append(section.text)
                currentCount += fullSectionCost
                continue
            }

            let remaining = budget - currentCount - separatorCount
            if remaining > 0 {
                let truncatedText = String(section.text.prefix(remaining))
                if !truncatedText.isEmpty {
                    keptSections.append(truncatedText)
                    currentCount += separatorCount + truncatedText.count
                }
            }

            trimmedSectionIDs.append(section.id)
            trimmedSectionIDs.append(contentsOf: sections[(index + 1)...].map(\.id))
            break
        }

        let renderedPrompt = keptSections.joined(separator: "\n\n")
        return Result(
            renderedPrompt: renderedPrompt,
            trimmedCharCount: max(fullPrompt.count - renderedPrompt.count, 0),
            postEnforcementPromptChars: renderedPrompt.count,
            trimmedSectionIDs: Array(NSOrderedSet(array: trimmedSectionIDs)) as? [String] ?? trimmedSectionIDs,
            totalPromptChars: fullPrompt.count
        )
    }
}