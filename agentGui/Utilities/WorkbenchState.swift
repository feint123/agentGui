import Observation

@Observable
@MainActor
final class WorkbenchState {
    var selectedItem: WorkbenchNavigationItem

    init(selectedItem: WorkbenchNavigationItem = .defaultItem) {
        self.selectedItem = selectedItem
    }
}