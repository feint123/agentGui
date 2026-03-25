import AppKit
import SwiftUI

struct WorkbenchContextTabCandidate: Equatable {
    let windowNumber: Int
    let tabbingIdentifier: String?
    let isKeyWindow: Bool
    let isVisible: Bool
}

struct WorkbenchContextWindowConfigurator: NSViewRepresentable {
    static let contextTabbingIdentifier = "workbench-context"

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

        if window.tabbingIdentifier != Self.contextTabbingIdentifier {
            window.tabbingIdentifier = Self.contextTabbingIdentifier
        }

        if window.tabbingMode != .preferred {
            window.tabbingMode = .preferred
        }

        mergeIntoExistingContextTabGroupIfNeeded(window)
    }

    private func mergeIntoExistingContextTabGroupIfNeeded(_ window: NSWindow) {
        guard window.tabbingIdentifier == Self.contextTabbingIdentifier else {
            return
        }

        if let tabbedWindows = window.tabbedWindows,
           tabbedWindows.contains(where: { $0 !== window }) {
            return
        }

        let incoming = WorkbenchContextTabCandidate(window: window)
        let candidates = NSApp.windows.map(WorkbenchContextTabCandidate.init(window:))

        guard let host = Self.preferredTabHost(for: incoming, candidates: candidates),
              let hostWindow = NSApp.windows.first(where: { $0.windowNumber == host.windowNumber }),
              hostWindow !== window else {
            return
        }

        hostWindow.addTabbedWindow(window, ordered: .above)
        window.makeKeyAndOrderFront(nil)
    }

    static func preferredTabHost(
        for incoming: WorkbenchContextTabCandidate,
        candidates: [WorkbenchContextTabCandidate]
    ) -> WorkbenchContextTabCandidate? {
        candidates
            .filter {
                $0.windowNumber != incoming.windowNumber &&
                $0.tabbingIdentifier == contextTabbingIdentifier &&
                $0.isVisible
            }
            .sorted {
                if $0.isKeyWindow != $1.isKeyWindow {
                    return $0.isKeyWindow && !$1.isKeyWindow
                }
                return $0.windowNumber < $1.windowNumber
            }
            .first
    }
}

private extension WorkbenchContextTabCandidate {
    init(window: NSWindow) {
        self.init(
            windowNumber: window.windowNumber,
            tabbingIdentifier: window.tabbingIdentifier,
            isKeyWindow: window.isKeyWindow,
            isVisible: window.isVisible
        )
    }
}