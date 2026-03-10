import Foundation

struct ChatComposerSlashState: Equatable {
    var query: String? = nil
    var candidates: [ChatSlashCommandItem] = []
    var highlightedItemID: String? = nil

    mutating func update(for text: String, registry: ChatSlashCommandRegistry) {
        guard let detected = ChatInputCommandParser.detectSlashQuery(in: text) else {
            clear()
            return
        }

        let items = registry.items(matching: detected.query)
        query = detected.query
        candidates = Array(items.prefix(8))

        if candidates.contains(where: { $0.id == highlightedItemID }) == false {
            highlightedItemID = candidates.first?.id
        }
    }

    mutating func moveSelection(delta: Int) {
        guard !candidates.isEmpty else { return }
        guard let highlightedItemID,
              let currentIndex = candidates.firstIndex(where: { $0.id == highlightedItemID }) else {
            self.highlightedItemID = candidates.first?.id
            return
        }

        let nextIndex = (currentIndex + delta + candidates.count) % candidates.count
        self.highlightedItemID = candidates[nextIndex].id
    }

    func selectHighlightedItem(in text: String) -> ChatInputCommandParser.ReplacementResult {
        guard let item = selectedItem ?? candidates.first else {
            return .init(updatedText: text, directive: nil)
        }
        return ChatInputCommandParser.replacingSlashToken(in: text, selectedItem: item)
    }

    mutating func clear() {
        query = nil
        candidates = []
        highlightedItemID = nil
    }

    var selectedItem: ChatSlashCommandItem? {
        guard let highlightedItemID else { return nil }
        return candidates.first(where: { $0.id == highlightedItemID })
    }
}