import Foundation

enum AppCommandID: String, CaseIterable, Identifiable {
    case showCommandPalette
    case checkForUpdates
    case showSettings
    case openWorkspaceChooser
    case showSessionsPanel
    case showWorkspacePanel
    case showGitPanel
    case showLSPPanel
    case showSkillsPanel
    case showDiagnosticsPanel
    case showNextSession
    case showPreviousSession
    case openContextWindow

    var id: String {
        rawValue
    }
}