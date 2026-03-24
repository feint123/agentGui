import SwiftUI

struct AppCommandRegistry {
    let descriptors: [AppCommandDescriptor]

    init(descriptors: [AppCommandDescriptor] = AppCommandRegistry.defaultDescriptors) {
        self.descriptors = descriptors
    }

    func descriptor(for id: AppCommandID) -> AppCommandDescriptor? {
        descriptors.first(where: { $0.id == id })
    }

    static let preview = AppCommandRegistry()

    private static let defaultDescriptors: [AppCommandDescriptor] = [
        AppCommandDescriptor(
            id: .showCommandPalette,
            title: "命令面板...",
            category: .app,
            menuPlacement: .appSettings,
            shortcut: AppCommandShortcut(key: "P", modifiers: [.command, .shift]),
            keywords: ["命令", "面板", "palette", "搜索"],
            requirement: .openWindow
        ),
        AppCommandDescriptor(
            id: .showSettings,
            title: "设置...",
            category: .app,
            menuPlacement: .appSettings,
            shortcut: AppCommandShortcut(key: ",", modifiers: .command),
            keywords: ["偏好设置", "设置", "preferences"],
            requirement: .openWindow
        ),
        AppCommandDescriptor(
            id: .showOnboarding,
            title: "开始使用...",
            category: .app,
            menuPlacement: .appSettings,
            shortcut: nil,
            keywords: ["开始使用", "欢迎", "onboarding"],
            requirement: .openWindow
        ),
        AppCommandDescriptor(
            id: .openWorkspaceChooser,
            title: "打开/切换工作区...",
            category: .workspace,
            menuPlacement: .newItem,
            shortcut: AppCommandShortcut(key: "o", modifiers: .command),
            keywords: ["工作区", "打开", "目录"],
            requirement: .none
        ),
        AppCommandDescriptor(
            id: .showAgentStudio,
            title: "显示 Agent 工作室",
            category: .window,
            menuPlacement: .windowArrangement,
            shortcut: AppCommandShortcut(key: "s", modifiers: [.command, .shift]),
            keywords: ["工作室", "studio", "窗口"],
            requirement: .openWindow
        ),
        AppCommandDescriptor(
            id: .showSessionsPanel,
            title: "切换到会话",
            category: .navigation,
            menuPlacement: .go,
            shortcut: AppCommandShortcut(key: "1", modifiers: .command),
            keywords: ["会话", "聊天", "面板"],
            requirement: .workbench
        ),
        AppCommandDescriptor(
            id: .showWorkspacePanel,
            title: "切换到工作区",
            category: .navigation,
            menuPlacement: .go,
            shortcut: AppCommandShortcut(key: "2", modifiers: .command),
            keywords: ["工作区", "文件", "面板"],
            requirement: .workbench
        ),
        AppCommandDescriptor(
            id: .showGitPanel,
            title: "切换到 Git",
            category: .navigation,
            menuPlacement: .go,
            shortcut: AppCommandShortcut(key: "3", modifiers: .command),
            keywords: ["git", "变更", "面板"],
            requirement: .workbench
        ),
        AppCommandDescriptor(
            id: .showLSPPanel,
            title: "切换到 LSP",
            category: .navigation,
            menuPlacement: .go,
            shortcut: AppCommandShortcut(key: "4", modifiers: .command),
            keywords: ["lsp", "语言服务", "面板"],
            requirement: .workbench
        ),
        AppCommandDescriptor(
            id: .showSkillsPanel,
            title: "切换到技能",
            category: .navigation,
            menuPlacement: .go,
            shortcut: AppCommandShortcut(key: "5", modifiers: .command),
            keywords: ["技能", "skills", "面板"],
            requirement: .workbench
        ),
        AppCommandDescriptor(
            id: .showDiagnosticsPanel,
            title: "切换到诊断",
            category: .navigation,
            menuPlacement: .go,
            shortcut: AppCommandShortcut(key: "6", modifiers: .command),
            keywords: ["诊断", "reliability", "面板"],
            requirement: .workbench
        ),
        AppCommandDescriptor(
            id: .showNextSession,
            title: "下一个会话",
            category: .session,
            menuPlacement: .go,
            shortcut: nil,
            keywords: ["会话", "下一个", "最近"],
            requirement: .workbenchWithSelectedSession
        ),
        AppCommandDescriptor(
            id: .showPreviousSession,
            title: "上一个会话",
            category: .session,
            menuPlacement: .go,
            shortcut: nil,
            keywords: ["会话", "上一个", "最近"],
            requirement: .workbenchWithSelectedSession
        ),
        AppCommandDescriptor(
            id: .openContextWindow,
            title: "打开上下文窗口",
            category: .window,
            menuPlacement: .go,
            shortcut: nil,
            keywords: ["上下文", "标签页", "窗口"],
            requirement: .workbench
        ),
        AppCommandDescriptor(
            id: .selectNextContextTab,
            title: "下一个上下文标签页",
            category: .window,
            menuPlacement: .go,
            shortcut: nil,
            keywords: ["上下文", "标签页", "下一个"],
            requirement: .contextWindowTabs
        ),
        AppCommandDescriptor(
            id: .selectPreviousContextTab,
            title: "上一个上下文标签页",
            category: .window,
            menuPlacement: .go,
            shortcut: nil,
            keywords: ["上下文", "标签页", "上一个"],
            requirement: .contextWindowTabs
        )
    ]
}