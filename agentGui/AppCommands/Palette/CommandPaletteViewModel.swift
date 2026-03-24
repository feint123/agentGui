import Foundation
import Observation

@Observable
@MainActor
final class CommandPaletteViewModel {
    var query: String = "" {
        didSet {
            refreshResults()
        }
    }

    private(set) var results: [CommandPaletteItem] = []
    private(set) var selectedItemID: String?
    private(set) var isPresented = false

    private let quickOpenProvider: QuickOpenProvider
    private let router: AppCommandRouter
    private var currentContext: AppCommandContext = .empty

    init(
        quickOpenProvider: QuickOpenProvider? = nil,
        router: AppCommandRouter? = nil
    ) {
        self.quickOpenProvider = quickOpenProvider ?? QuickOpenProvider()
        self.router = router ?? AppCommandRouter()
        NotificationCenter.default.addObserver(
            forName: CommandPaletteWindowScene.presentNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let request = notification.object as? CommandPalettePresentationRequest else { return }
            Task { @MainActor in
                self?.present(using: request.context)
            }
        }
    }

    var selectedItem: CommandPaletteItem? {
        guard let selectedItemID else { return results.first }
        return results.first(where: { $0.id == selectedItemID }) ?? results.first
    }

    var sections: [CommandPaletteSection] {
        var orderedSections: [CommandPaletteSection] = []

        for group in CommandPaletteItemGroup.allCases {
            let items = results.filter { $0.group == group }
            guard !items.isEmpty else { continue }
            orderedSections.append(CommandPaletteSection(group: group, items: items))
        }

        return orderedSections
    }

    var resultCountDescription: String {
        "\(results.count) 个结果"
    }

    func present(using context: AppCommandContext) {
        currentContext = context
        isPresented = true
        query = ""
        refreshResults()
    }

    func moveSelection(downward: Bool) {
        guard !results.isEmpty else { return }
                guard let currentSelectedItemID = selectedItemID,
                            let currentIndex = results.firstIndex(where: { $0.id == currentSelectedItemID }) else {
            self.selectedItemID = results.first?.id
            return
        }

        let nextIndex = downward
            ? (currentIndex + 1) % results.count
            : (currentIndex - 1 + results.count) % results.count
        selectedItemID = results[nextIndex].id
    }

    func executeSelected() async -> Bool {
        guard let selectedItem else { return false }
        return await execute(selectedItem)
    }

    func execute(_ item: CommandPaletteItem) async -> Bool {
        guard item.isEnabled else { return false }

        switch item.payload {
        case .command(let commandID):
            _ = await router.perform(commandID, in: currentContext)
        case .recentWorkspace(let url):
            guard let modelContext = currentContext.modelContext else { return false }
            let didApply = WorkspaceDirectorySelectionCoordinator.applySelection(
                url,
                workspaceState: currentContext.workspaceState,
                modelContext: modelContext,
                persistenceCoordinator: .shared,
                userMessage: "工作目录未成功保存"
            )
            guard didApply else { return false }
        case .recentSession(let session):
            currentContext.workspaceState?.selectedSession = session
        case .file(let fileURL):
            currentContext.workspaceState?.showFileDetail(fileURL)
        }

        isPresented = false
        return true
    }

    func markDismissed() {
        isPresented = false
    }

    private func refreshResults() {
        results = quickOpenProvider.results(query: query, context: currentContext)

        if let selectedItemID,
           results.contains(where: { $0.id == selectedItemID }) {
            return
        }

        selectedItemID = results.first?.id
    }
}

struct CommandPaletteSection: Identifiable {
    let group: CommandPaletteItemGroup
    let items: [CommandPaletteItem]

    var id: Int {
        group.rawValue
    }
}