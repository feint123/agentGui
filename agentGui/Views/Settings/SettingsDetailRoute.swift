import Foundation

enum SettingsDetailRoute: String, Hashable, Identifiable, Sendable {
    case memoryGovernance

    var id: String { rawValue }
}