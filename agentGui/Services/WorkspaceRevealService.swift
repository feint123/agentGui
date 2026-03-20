import AppKit
import Foundation

protocol WorkspaceFinderClient {
    func activateFileViewerSelecting(_ urls: [URL])
}

struct LiveWorkspaceFinderClient: WorkspaceFinderClient {
    func activateFileViewerSelecting(_ urls: [URL]) {
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }
}

protocol WorkspaceRevealServing {
    func revealInFinder(_ urls: [URL])
}

struct WorkspaceRevealService: WorkspaceRevealServing {
    private let client: WorkspaceFinderClient

    init(client: WorkspaceFinderClient = LiveWorkspaceFinderClient()) {
        self.client = client
    }

    func revealInFinder(_ urls: [URL]) {
        let normalized = Array(Set(urls.map(\.standardizedFileURL)))
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        guard !normalized.isEmpty else { return }
        client.activateFileViewerSelecting(normalized)
    }
}