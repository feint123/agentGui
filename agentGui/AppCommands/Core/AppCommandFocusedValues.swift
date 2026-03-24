import SwiftUI

private struct AppCommandContextFocusedValueKey: FocusedValueKey {
    typealias Value = AppCommandContext
}

extension FocusedValues {
    var appCommandContext: AppCommandContext? {
        get { self[AppCommandContextFocusedValueKey.self] }
        set { self[AppCommandContextFocusedValueKey.self] = newValue }
    }
}