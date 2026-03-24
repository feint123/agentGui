import SwiftUI

enum AppCommandCategory: String, CaseIterable {
    case app
    case workspace
    case session
    case navigation
    case window
}

enum AppCommandMenuPlacement: Equatable {
    case appSettings
    case newItem
    case windowArrangement
    case go
}

struct AppCommandShortcut: Equatable {
    let key: String
    let modifiers: EventModifiers
}

struct AppCommandDescriptor: Identifiable, Equatable {
    let id: AppCommandID
    let title: String
    let category: AppCommandCategory
    let menuPlacement: AppCommandMenuPlacement?
    let shortcut: AppCommandShortcut?
    let keywords: [String]
    let requirement: AppCommandRequirement
}