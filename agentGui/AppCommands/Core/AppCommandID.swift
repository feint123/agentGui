import Foundation

enum AppCommandID: String, CaseIterable, Identifiable {
    case showCommandPalette
    case showSettings
    case showOnboarding
    case openWorkspaceChooser
    case showAgentStudio
    case showSessionsPanel
    case showWorkspacePanel
    case showGitPanel
    case showLSPPanel
    case showSkillsPanel
    case showDiagnosticsPanel
    case showNextSession
    case showPreviousSession
    case openContextWindow
    case selectNextContextTab
    case selectPreviousContextTab

    var id: String {
        rawValue
    }
}