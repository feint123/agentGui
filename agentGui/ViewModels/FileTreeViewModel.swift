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

    // MARK: - 初始化

    init(store: FileTreeStore) {
        self.store = store
    }

    // MARK: - 目录操作

    /// 设置工作区根目录。传 nil 时清空所有状态。
    func setDirectory(_ url: URL?) async {
        guard let url else {
            visibleEntries = []
            selection = .init()
            return
        }
        await store.setRoot(url)
        visibleEntries = await store.computeVisibleEntries()
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

    // MARK: - 内部刷新（FSEvent 触发）

    /// 仅重新计算可见列表，不改变展开状态。
    /// 由 FSEventObserver 回调时使用。
    func refreshVisibleEntries() async {
        visibleEntries = await store.computeVisibleEntries()
    }
}
