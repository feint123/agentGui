import Foundation
import Observation

struct WorkbenchContextTab: Identifiable, Equatable {
    let id: UUID
    var selection: WorkbenchDetailSelection

    init(id: UUID = UUID(), selection: WorkbenchDetailSelection) {
        self.id = id
        self.selection = Self.normalize(selection)
    }

    func matches(_ other: WorkbenchDetailSelection) -> Bool {
        let normalizedOther = Self.normalize(other)

        switch (selection, normalizedOther) {
        case (.changeProposal(let lhsProposalID, _), .changeProposal(let rhsProposalID, _)):
            return lhsProposalID == rhsProposalID
        default:
            return selection == normalizedOther
        }
    }

    static func normalize(_ selection: WorkbenchDetailSelection) -> WorkbenchDetailSelection {
        switch selection {
        case .none:
            return .none
        case .file(let fileURL):
            return .file(fileURL.standardizedFileURL)
        case .gitDiff(let title, let diffText):
            return .gitDiff(title: title, diffText: diffText)
        case .changeProposal(let proposalID, let filePath):
            return .changeProposal(proposalID: proposalID, filePath: filePath)
        }
    }
}

@Observable
@MainActor
final class WorkbenchContextWindowState {
    private(set) var tabs: [WorkbenchContextTab] = []
    var selectedTabID: UUID?
    private(set) var openRequestToken = 0

    var selectedTab: WorkbenchContextTab? {
        if let selectedTabID,
           let selectedTab = tabs.first(where: { $0.id == selectedTabID }) {
            return selectedTab
        }

        return tabs.first
    }

    var hasTabs: Bool {
        !tabs.isEmpty
    }

    var hasMultipleTabs: Bool {
        tabs.count > 1
    }

    func open(_ selection: WorkbenchDetailSelection) {
        let normalizedSelection = WorkbenchContextTab.normalize(selection)
        guard normalizedSelection != .none else { return }

        if let existingIndex = tabs.firstIndex(where: { $0.matches(normalizedSelection) }) {
            tabs[existingIndex].selection = merge(
                existing: tabs[existingIndex].selection,
                incoming: normalizedSelection
            )
            selectedTabID = tabs[existingIndex].id
        } else {
            let tab = WorkbenchContextTab(selection: normalizedSelection)
            tabs.append(tab)
            selectedTabID = tab.id
        }

        requestPresentation()
    }

    func requestPresentation() {
        openRequestToken += 1
    }

    func selectTab(id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        selectedTabID = id
    }

    func closeTab(id: UUID) {
        guard let tabIndex = tabs.firstIndex(where: { $0.id == id }) else { return }

        tabs.remove(at: tabIndex)

        guard !tabs.isEmpty else {
            selectedTabID = nil
            return
        }

        if selectedTabID == id {
            let nextIndex = min(tabIndex, tabs.count - 1)
            selectedTabID = tabs[nextIndex].id
        }
    }

    func closeAllTabs() {
        tabs.removeAll()
        selectedTabID = nil
    }

    func closeOtherTabs(keeping tabID: UUID) {
        guard let tab = tabs.first(where: { $0.id == tabID }) else { return }
        tabs = [tab]
        selectedTabID = tabID
    }

    func closeTabsToRight(of tabID: UUID) {
        guard let tabIndex = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        tabs = Array(tabs.prefix(tabIndex + 1))
        if !tabs.contains(where: { $0.id == selectedTabID }) {
            selectedTabID = tabID
        }
    }

    func selectNextTab() {
        guard !tabs.isEmpty else { return }
        guard let selectedTabID,
              let selectedIndex = tabs.firstIndex(where: { $0.id == selectedTabID }) else {
            self.selectedTabID = tabs[0].id
            return
        }

        let nextIndex = (selectedIndex + 1) % tabs.count
        self.selectedTabID = tabs[nextIndex].id
    }

    func selectPreviousTab() {
        guard !tabs.isEmpty else { return }
        guard let selectedTabID,
              let selectedIndex = tabs.firstIndex(where: { $0.id == selectedTabID }) else {
            self.selectedTabID = tabs[0].id
            return
        }

        let previousIndex = (selectedIndex - 1 + tabs.count) % tabs.count
        self.selectedTabID = tabs[previousIndex].id
    }

    func updateChangeProposalFilePath(proposalID: UUID, filePath: String?) {
        guard let tabIndex = tabs.firstIndex(where: {
            if case .changeProposal(let currentProposalID, _) = $0.selection {
                return currentProposalID == proposalID
            }
            return false
        }) else {
            return
        }

        tabs[tabIndex].selection = .changeProposal(proposalID: proposalID, filePath: filePath)
    }

    func updateChangeProposalFilePath(forTabID tabID: UUID, filePath: String?) {
        guard let tabIndex = tabs.firstIndex(where: { $0.id == tabID }),
              case .changeProposal(let proposalID, _) = tabs[tabIndex].selection else {
            return
        }

        tabs[tabIndex].selection = .changeProposal(proposalID: proposalID, filePath: filePath)
    }

    private func merge(
        existing: WorkbenchDetailSelection,
        incoming: WorkbenchDetailSelection
    ) -> WorkbenchDetailSelection {
        switch (existing, incoming) {
        case (.changeProposal(let proposalID, let existingFilePath), .changeProposal(_, let incomingFilePath)):
            return .changeProposal(proposalID: proposalID, filePath: incomingFilePath ?? existingFilePath)
        default:
            return incoming
        }
    }
}