// agentGui/Views/FileTree/FileTreeContextMenu.swift
//
// 设计参考：
//   Zed   crates/project_panel/src/project_panel.rs — deploy_context_menu / ContextMenu::build
//   VSCode src/vs/workbench/contrib/files/browser/views/explorerView.ts — onContextMenu + MenuId.ExplorerContext context keys
//
// 菜单顺序（与 VSCode Explorer 对齐）：
//   新建文件 / 新建文件夹
//   [分隔符]
//   重命名（单选且非根）/ 删除（有选中且非根）
//   [分隔符]
//   在访达中显示 / 复制相对路径
//   [分隔符 + 查看 Diff（仅 Git 变更文件）]

import AppKit

enum FileTreeContextMenu {

    // MARK: - Config

    /// 构建上下文菜单所需的全部上下文，参考 Zed 的 deploy_context_menu 参数集合。
    struct Config {
        /// 右键点击的条目（nil = 在空白区域点击）
        let targetEntry: VisibleEntry?
        /// 当前选中的全部条目
        let selectedEntries: [VisibleEntry]
        /// 点击的条目是否为根目录（parentID == nil）
        /// Zed: !is_root 门控 Rename/Delete；VSCode: explorerItemIsRoot context key
        let isRoot: Bool
        /// 工作区根路径，用于计算相对路径
        let rootURL: URL?

        // ── 动作回调（对应 Zed ContextMenu::build 中的 .action(...)）
        /// 新建文件（⌘N）
        let onNewFile: () -> Void
        /// 新建文件夹（⌘⇧N）
        let onNewFolder: () -> Void
        /// 重命名（Return）— 仅单选且非根时启用
        let onRename: () -> Void
        /// 删除（⌫）— 有选中且非根时显示
        let onDelete: () -> Void
        /// 在访达中显示（⌘R）
        let onRevealInFinder: () -> Void
        /// 复制相对路径（⌥⌘C）
        let onCopyPath: () -> Void
        /// 查看 Git Diff — nil 表示目标文件无 Git 变更，不显示此项
        /// VSCode: isDirty / isInGitRepository context key 门控
        let onPreviewDiff: (() -> Void)?
    }

    // MARK: - 菜单工厂

    /// 根据 Config 构建 NSMenu。
    /// 纯函数：不保存任何状态，不访问全局，便于单元测试。
    static func build(_ config: Config) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        // ── Zed: 始终显示新建（参考 ContextMenu::build 中 .action("New File", ...) 无任何条件）
        menu.addItem(item(title: "新建文件",   key: "n",  modifiers: .command,        action: config.onNewFile))
        menu.addItem(item(title: "新建文件夹", key: "N",  modifiers: [.command, .shift], action: config.onNewFolder))

        let hasSelection = !config.selectedEntries.isEmpty
        let isSingleSelection = config.selectedEntries.count == 1

        // ── Zed: .when(!is_root, ...) 门控 Rename/Delete
        if hasSelection && !config.isRoot {
            menu.addItem(.separator())

            // Rename — VSCode: 多选时 isEnabled = false（explorerItemIsHighlighted = false）
            let renameItem = item(title: "重命名", key: "\r", modifiers: [], action: config.onRename)
            renameItem.isEnabled = isSingleSelection   // 多选时禁用，单选时启用
            menu.addItem(renameItem)

            menu.addItem(item(title: "删除", key: String(UnicodeScalar(NSDeleteCharacter)!), modifiers: [], action: config.onDelete))
        }

        // ── 访达 + 路径（不受 isRoot 限制，参考 VSCode 中根目录也能 Reveal in Finder）
        menu.addItem(.separator())
        menu.addItem(item(title: "在访达中显示", key: "r",  modifiers: .command,           action: config.onRevealInFinder))
        menu.addItem(item(title: "复制相对路径", key: "c",  modifiers: [.command, .option], action: config.onCopyPath))

        // ── Git Diff — VSCode: isDirty context key；Zed: entry.git_status.is_some()
        if let onDiff = config.onPreviewDiff {
            menu.addItem(.separator())
            menu.addItem(item(title: "查看 Diff", key: "", modifiers: [], action: onDiff))
        }

        return menu
    }

    // MARK: - NSMenuItem 辅助（闭包桥接）

    /// 创建带闭包的 NSMenuItem。
    /// 使用 HandlerInterceptor 作为 target，避免 target/action 字符串分发的脆弱性。
    private static func item(
        title: String,
        key: String,
        modifiers: NSEvent.ModifierFlags,
        action closure: @escaping () -> Void
    ) -> NSMenuItem {
        let interceptor = HandlerInterceptor(closure)
        let menuItem = NSMenuItem(
            title: title,
            action: #selector(HandlerInterceptor.invoke),
            keyEquivalent: key
        )
        menuItem.keyEquivalentModifierMask = modifiers
        menuItem.target = interceptor
        menuItem.representedObject = interceptor   // 强持有，防 ARC 回收
        menuItem.isEnabled = true
        return menuItem
    }
}

// MARK: - HandlerInterceptor（私有桥接）

/// NSMenuItem target 的闭包桥接，替代旧代码 `target: AnyObject, action: Selector` 模式。
/// 每个 NSMenuItem 持有自己的 HandlerInterceptor 实例，与菜单生命周期绑定。
private final class HandlerInterceptor: NSObject {
    private let closure: () -> Void

    init(_ closure: @escaping () -> Void) {
        self.closure = closure
    }

    @objc func invoke() {
        closure()
    }
}
