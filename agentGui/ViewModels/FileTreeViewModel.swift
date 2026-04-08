// agentGui/ViewModels/FileTreeViewModel.swift
import Foundation
import Observation

/// 调用者通过此枚举指定点击时的修饰键语义。
enum SelectionModifier {
    case none       // 普通单击：仅选中此项
    case add        // ⌘ 单击：追加/取消
    case range      // ⇧ 单击：从 anchor 到此项范围选择
}

/// FT-R2 ViewModel：桥接 FileTreeStore（actor 层）与 SwiftUI/NSTableView 展示层。
///
/// 对标 Zed project_panel.rs 中 `update_visible_entries()` → `visible_entries` 数据管道，
/// 以及 VSCode explorerViewer.ts 中 IAsyncDataTreeViewState 的分离原则：
/// 展开状态完全由外部（FileTreeStore）管理，UI 层只读取快照。
@Observable @MainActor
final class FileTreeViewModel {

    // MARK: - 公开状态（@Observable 自动追踪）

    /// 当前可见行的扁平列表，供 NSTableView 直接消费（Zed: visible_entries）
    private(set) var visibleEntries: [VisibleEntry] = []

    /// 当前选中状态（含多选和 anchor）
    var selection: FileTreeSelection = .init()

    /// 最近一次目录扫描失败的本地化描述。
    /// 参考 VSCode ExplorerView 的 `tree.setInput(null)` 错误恢复模式。
    var errorMessage: String? = nil

    // MARK: - 私有

    private let store: FileTreeStore
    // FT-R7: Git 状态观察者
    private var gitStatusObserver: (any GitStatusObserving)?

    // MARK: - 初始化

    init(store: FileTreeStore, settings: AppSettings? = nil) {
        self.store = store
        // 从 AppSettings 同步 compactFolders 初始值
        let compact = settings?.compactFolders ?? true
        self.isCompactFoldersEnabled = compact
        Task { [weak self] in
            await self?.store.setCompactFolders(compact)
        }
    }

    // MARK: - 目录操作

    /// 设置工作区根目录。传 nil 时清空所有状态。
    func setDirectory(_ url: URL?) async {
        // 停止旧的 Git 观察者
        gitStatusObserver?.stop()
        gitStatusObserver = nil

        guard let url else {
            visibleEntries = []
            selection = .init()
            return
        }
        await store.setRoot(url)
        visibleEntries = await store.computeVisibleEntries()

        // 启动 Git 状态观察
        let observer = GitStatusObserver()
        observer.start(rootURL: url) { [weak self] statuses in
            guard let self else { return }
            Task {
                await self.store.updateGitStatuses(statuses)
                self.visibleEntries = await self.store.computeVisibleEntries()
            }
        }
        gitStatusObserver = observer
    }

    /// 切换目录展开/折叠状态，更新 visibleEntries 快照。
    ///
    /// 展开失败（扫描错误）时：
    /// - `errorMessage` 设为本地化错误描述（Zed 在 status_bar 显示错误，本实现由调用层绑定）
    /// - visibleEntries 维持原状（FileTreeStore 已完成回退）
    func toggleDirectory(_ id: EntryID) async {
        if await store.isExpanded(id) {
            await store.collapseDirectory(id)
            errorMessage = nil
        } else {
            do {
                try await store.expandDirectory(id)
                errorMessage = nil   // 成功展开后清除上次错误
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        visibleEntries = await store.computeVisibleEntries()
    }

    // MARK: - 选择操作

    /// 处理行点击事件，根据修饰键更新 selection。
    ///
    /// 对标 VSCode explorerViewer.ts `onMouseClick()`，以及
    /// Zed project_panel.rs `on_click()` 中的 shift/secondary modifier 分支。
    func selectEntry(_ id: EntryID, modifier: SelectionModifier) {
        switch modifier {
        case .none:
            selection.setSingle(id)

        case .add:
            // ⌘ 单击：已选中则取消，未选中则追加
            selection.toggle(id)
            selection.anchor = id

        case .range:
            // ⇧ 单击：从 anchor 到 id 的连续范围，加入 selected
            guard let anchor = selection.anchor,
                  let anchorIdx = visibleEntries.firstIndex(where: { $0.id == anchor }),
                  let targetIdx = visibleEntries.firstIndex(where: { $0.id == id })
            else {
                selection.setSingle(id)
                return
            }
            let lo = min(anchorIdx, targetIdx)
            let hi = max(anchorIdx, targetIdx)
            let rangeIDs = visibleEntries[lo...hi].map(\.id)
            let currentAnchor = selection.anchor ?? id
            selection = FileTreeSelection(primary: id, selected: rangeIDs, anchor: currentAnchor)
        }
    }

    // MARK: - Auto-fold（FT-R5）

    /// 当前 compactFolders 状态（供 UI 读取）。
    private(set) var isCompactFoldersEnabled: Bool = true

    /// 透传 compactFolders 设置到 Store，并刷新可见列表。
    func setCompactFolders(_ value: Bool) async {
        isCompactFoldersEnabled = value
        await store.setCompactFolders(value)
        await refreshVisibleEntries()
    }

    /// 将目录从自动折叠链中手动展开（加入 unfoldedIDs），并刷新可见列表。
    func unfoldDirectory(_ id: EntryID) async {
        await store.unfoldDirectory(id)
        await refreshVisibleEntries()
    }

    /// 将目录重新纳入自动折叠（从 unfoldedIDs 移除），并刷新可见列表。
    func foldDirectory(_ id: EntryID) async {
        await store.foldDirectory(id)
        await refreshVisibleEntries()
    }

    // MARK: - 内部刷新（FSEvent 触发）

    /// 仅重新计算可见列表，不改变展开状态。
    /// 由 FSEventObserver 回调时使用。
    func refreshVisibleEntries() async {
        visibleEntries = await store.computeVisibleEntries()
    }
}
