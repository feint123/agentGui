struct ComposerAssistSelectionController: Equatable {
    var itemCount: Int
    var selectedIndex: Int?

    init(itemCount: Int, selectedIndex: Int? = nil) {
        self.itemCount = max(itemCount, 0)
        if let selectedIndex,
           selectedIndex >= 0,
           selectedIndex < itemCount {
            self.selectedIndex = selectedIndex
        } else {
            self.selectedIndex = itemCount > 0 ? 0 : nil
        }
    }

    mutating func move(delta: Int) {
        guard itemCount > 0 else {
            selectedIndex = nil
            return
        }

        let currentIndex = selectedIndex ?? 0
        let nextIndex = (currentIndex + delta).quotientAndRemainder(dividingBy: itemCount).remainder
        selectedIndex = nextIndex >= 0 ? nextIndex : nextIndex + itemCount
    }
}