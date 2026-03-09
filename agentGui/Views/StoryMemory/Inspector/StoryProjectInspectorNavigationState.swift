import Foundation
import Observation

@Observable
final class StoryProjectInspectorNavigationState {
    private var selectedTabsByProjectID: [UUID: StoryProjectInspectorTab] = [:]

    func selectedTab(for projectID: UUID) -> StoryProjectInspectorTab {
        selectedTabsByProjectID[projectID] ?? .overview
    }

    func select(_ tab: StoryProjectInspectorTab, for projectID: UUID) {
        selectedTabsByProjectID[projectID] = tab
    }
}