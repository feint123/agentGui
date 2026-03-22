import AppKit
import SwiftUI

struct WorkbenchTitlePresentation: Equatable {
    let title: String
    let subtitle: String
    let representedURL: URL?

    static func make(
        selectedItem: WorkbenchNavigationItem,
        workspaceState: WorkspaceState,
        globalWorkingDirectory: String
    ) -> WorkbenchTitlePresentation {
        guard selectedItem == .workspace else {
            return WorkbenchTitlePresentation(
                title: selectedItem.title,
                subtitle: "",
                representedURL: nil
            )
        }

        let presentation = SessionWorkspacePresentationFactory().build(
            session: workspaceState.selectedSession,
            globalWorkingDirectory: globalWorkingDirectory
        )

        guard let directoryURL = presentation.representedURL else {
            return WorkbenchTitlePresentation(
                title: presentation.title,
                subtitle: "",
                representedURL: nil
            )
        }

        return WorkbenchTitlePresentation(
            title: presentation.title,
            subtitle: presentation.subtitle,
            representedURL: directoryURL
        )
    }
}

struct WorkbenchWindowConfigurator: NSViewRepresentable {
    let presentation: WorkbenchTitlePresentation

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            configureWindow(for: view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            configureWindow(for: nsView)
        }
    }

    private func configureWindow(for view: NSView) {
        guard let window = view.window else { return }

        if window.title != presentation.title {
            window.title = presentation.title
        }

        if window.subtitle != presentation.subtitle {
            window.subtitle = presentation.subtitle
        }

        if window.representedURL != presentation.representedURL {
            window.representedURL = presentation.representedURL
        }
    }
}