import Foundation

struct AppCommandAvailability: Equatable {
    let isEnabled: Bool
    let disabledReason: String?

    static let enabled = AppCommandAvailability(isEnabled: true, disabledReason: nil)

    static func disabled(_ reason: String) -> AppCommandAvailability {
        AppCommandAvailability(isEnabled: false, disabledReason: reason)
    }
}

enum AppCommandResult: Equatable {
    case performed
    case disabled(String)
    case failed(String)
}