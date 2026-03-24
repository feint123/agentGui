import Foundation
import SwiftUI

enum CommandPaletteItemPayload {
    case command(AppCommandID)
    case recentWorkspace(URL)
    case recentSession(Session)
    case file(URL)
}

enum CommandPaletteItemGroup: Int, CaseIterable {
    case recentSessions
    case recentWorkspaces
    case commands
    case files

    var title: String {
        switch self {
        case .recentSessions:
            return "最近会话"
        case .recentWorkspaces:
            return "最近工作区"
        case .commands:
            return "命令"
        case .files:
            return "文件"
        }
    }
}

struct CommandPaletteItem: Identifiable {
    let id: String
    let group: CommandPaletteItemGroup
    let title: String
    let subtitle: String?
    let systemImage: String
    let accessoryTitle: String?
    let keywords: [String]
    let isEnabled: Bool
    let disabledReason: String?
    let payload: CommandPaletteItemPayload
}

@MainActor
struct QuickOpenProvider {
    let registry: AppCommandRegistry
    let recentWorkspaceStore: RecentWorkspaceStore
    let recentSessionProvider: RecentSessionProvider
    let workspaceFileSearchIndex: WorkspaceFileSearchIndex

    init(
        registry: AppCommandRegistry? = nil,
        recentWorkspaceStore: RecentWorkspaceStore? = nil,
        recentSessionProvider: RecentSessionProvider? = nil,
        workspaceFileSearchIndex: WorkspaceFileSearchIndex? = nil
    ) {
        self.registry = registry ?? AppCommandRegistry()
        self.recentWorkspaceStore = recentWorkspaceStore ?? .shared
        self.recentSessionProvider = recentSessionProvider ?? RecentSessionProvider()
        self.workspaceFileSearchIndex = workspaceFileSearchIndex ?? WorkspaceFileSearchIndex()
    }

    func results(query: String, context: AppCommandContext) -> [CommandPaletteItem] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let commandItems = commandItems(context: context)
        let recentWorkspaceItems = recentWorkspaceItems(query: trimmedQuery, context: context)
        let recentSessionItems = recentSessionItems(query: trimmedQuery, context: context)

        var items = recentSessionItems + recentWorkspaceItems + commandItems

        if let rootURL = workingDirectoryURL(for: context), !trimmedQuery.isEmpty {
            items.append(contentsOf: fileItems(query: trimmedQuery, rootURL: rootURL))
        }

        guard !trimmedQuery.isEmpty else {
            return Array(items.prefix(24))
        }

        let rankedItems: [(item: CommandPaletteItem, score: Int)] = items.compactMap { item in
            guard let score = score(for: item, query: trimmedQuery) else {
                return nil
            }
            return (item: item, score: score)
        }

        return rankedItems.sorted { (lhs: (item: CommandPaletteItem, score: Int), rhs: (item: CommandPaletteItem, score: Int)) in
            if lhs.1 != rhs.1 {
                return lhs.1 > rhs.1
            }
            if lhs.0.group != rhs.0.group {
                return lhs.0.group.rawValue < rhs.0.group.rawValue
            }
            return lhs.0.title.localizedStandardCompare(rhs.0.title) == .orderedAscending
        }
        .map { entry in
            entry.0
        }
    }

    private func commandItems(context: AppCommandContext) -> [CommandPaletteItem] {
        registry.descriptors.map { descriptor in
            let availability = descriptor.requirement.evaluate(in: context)
            return CommandPaletteItem(
                id: "command:\(descriptor.id.rawValue)",
                group: .commands,
                title: descriptor.title,
                subtitle: descriptor.keywords.joined(separator: " · "),
                systemImage: systemImage(for: descriptor.category),
                accessoryTitle: shortcutTitle(for: descriptor.shortcut),
                keywords: descriptor.keywords,
                isEnabled: availability.isEnabled,
                disabledReason: availability.disabledReason,
                payload: .command(descriptor.id)
            )
        }
    }

    private func recentWorkspaceItems(query: String, context: AppCommandContext) -> [CommandPaletteItem] {
        let items = recentWorkspaceStore.items
        let filtered = query.isEmpty ? Array(items.prefix(5)) : items.filter {
            $0.displayName.localizedStandardContains(query) || $0.path.localizedStandardContains(query)
        }

        let isEnabled = context.modelContext != nil
        let disabledReason = isEnabled ? nil : "当前窗口没有可用的持久化上下文。"

        return filtered.map { item in
            CommandPaletteItem(
                id: "workspace:\(item.path)",
                group: .recentWorkspaces,
                title: item.displayName,
                subtitle: item.path,
                systemImage: "folder",
                accessoryTitle: "最近",
                keywords: [item.displayName, item.path, "最近工作区"],
                isEnabled: isEnabled,
                disabledReason: disabledReason,
                payload: .recentWorkspace(URL(fileURLWithPath: item.path))
            )
        }
    }

    private func recentSessionItems(query: String, context: AppCommandContext) -> [CommandPaletteItem] {
        let sessions = recentSessionProvider.recentSessions(modelContext: context.modelContext)
        let filtered = query.isEmpty ? Array(sessions.prefix(5)) : sessions.filter {
            $0.title.localizedStandardContains(query) ||
            $0.displaySourceTitle.localizedStandardContains(query) ||
            $0.lastMessagePreview.localizedStandardContains(query)
        }

        let isEnabled = context.workspaceState != nil
        let disabledReason = isEnabled ? nil : "当前没有可操作的工作台窗口。"

        return filtered.map { session in
            CommandPaletteItem(
                id: "session:\(session.sessionId)",
                group: .recentSessions,
                title: session.title,
                subtitle: session.displaySourceTitle,
                systemImage: "bubble.left.and.bubble.right",
                accessoryTitle: "最近",
                keywords: [session.title, session.displaySourceTitle, session.lastMessagePreview],
                isEnabled: isEnabled,
                disabledReason: disabledReason,
                payload: .recentSession(session)
            )
        }
    }

    private func fileItems(query: String, rootURL: URL) -> [CommandPaletteItem] {
        let results = (try? workspaceFileSearchIndex.search(query: query, rootURL: rootURL)) ?? []
        return results.map { result in
            CommandPaletteItem(
                id: "file:\(result.fileURL.path)",
                group: .files,
                title: URL(fileURLWithPath: result.relativePath).lastPathComponent,
                subtitle: result.relativePath,
                systemImage: "doc.text",
                accessoryTitle: "文件",
                keywords: [result.relativePath, result.fileURL.path],
                isEnabled: true,
                disabledReason: nil,
                payload: .file(result.fileURL)
            )
        }
    }

    private func score(for item: CommandPaletteItem, query: String) -> Int? {
        let normalizedQuery = query.lowercased()
        let normalizedTitle = item.title.lowercased()

        if item.title == query {
            return 120
        }

        if normalizedTitle.hasPrefix(normalizedQuery) {
            return 110
        }

        if item.title.localizedStandardContains(query) {
            return 90
        }

        if let subtitle = item.subtitle, subtitle.localizedStandardContains(query) {
            return 68 + groupBoost(for: item.group)
        }

        if item.keywords.contains(where: { $0.localizedStandardContains(query) }) {
            return 56 + groupBoost(for: item.group)
        }

        return nil
    }

    private func groupBoost(for group: CommandPaletteItemGroup) -> Int {
        switch group {
        case .recentSessions:
            return 8
        case .recentWorkspaces:
            return 6
        case .commands:
            return 4
        case .files:
            return 0
        }
    }

    private func workingDirectoryURL(for context: AppCommandContext) -> URL? {
        if let path = context.workspaceState?.selectedSession?.workingDirectory,
           !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: path).standardizedFileURL
        }

        guard let modelContext = context.modelContext else { return nil }
        let globalPath = AppSettings.getOrCreate(in: modelContext).workingDirectory
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !globalPath.isEmpty else { return nil }
        return URL(fileURLWithPath: globalPath).standardizedFileURL
    }

    private func systemImage(for category: AppCommandCategory) -> String {
        switch category {
        case .app:
            return "command"
        case .workspace:
            return "folder"
        case .session:
            return "bubble.left.and.bubble.right"
        case .navigation:
            return "sidebar.left"
        case .window:
            return "macwindow"
        }
    }

    private func shortcutTitle(for shortcut: AppCommandShortcut?) -> String? {
        guard let shortcut else { return nil }

        let modifierTitles: [(EventModifiers, String)] = [
            (.control, "⌃"),
            (.option, "⌥"),
            (.shift, "⇧"),
            (.command, "⌘")
        ]

        let prefix = modifierTitles
            .filter { shortcut.modifiers.contains($0.0) }
            .map { modifierTitle in
                modifierTitle.1
            }
            .joined()

        return prefix + shortcut.key.uppercased()
    }
}