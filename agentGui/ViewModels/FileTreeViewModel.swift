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

    // MARK: - 公개状态（@Observable 自动追踪）

    /// 当前可见行的扁平列表，供 NSTableView 直接消费（Zed: visible_entries）
    var visibleEntries: [VisibleEntry] = []

    /// 当前选中状态（含多选和 anchor）
    var selection: FileTreeSelection = .init()

    /// 最近一次目录扫描失败的本地化描述。
    /// 参考 VSCode ExplorerView 的 `tree.setInput(null)` 错误恢复模式。
    var errorMessage: String? = nil

    /// FT-R9: Store 的只读快照，供 FileTreeDropValidator 在主线程同步查询。
    /// 每次 visibleEntries 刷新时一并更新。
    private(set) var storeSnapshot: FileTreeStoreSnapshot? = nil

    // MARK: - 内联编辑（FT-R8）

    /// 当前根目录（setDirectory 时更新，供 beginCreate 回退到根插入位置使用）。
    private(set) var rootDirectory: URL? = nil

    /// 当前内联编辑会话（nil = 非编辑态）。
    /// 对标 Zed `ProjectPanel.edit_state: Option<EditState>`（project_panel.rs）。
    var inlineEdit: InlineEditSession? = nil

    /// 最近一次实时校验错误（供 FileTreeCellView 读取以高亮显示）。
    var validationError: EditValidationError? = nil

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

        rootDirectory = url

        guard let url else {
            visibleEntries = []
            selection = .init()
            return
        }
        await store.setRoot(url)
        visibleEntries = await store.computeVisibleEntries()
        storeSnapshot = await store.makeSnapshot()

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
        storeSnapshot = await store.makeSnapshot()
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
        storeSnapshot = await store.makeSnapshot()
    }

    // MARK: - 内联编辑：开始（FT-R8）

    /// 开始新建文件 / 新建文件夹，在 selectedID 之后插入占位行。
    ///
    /// 插入位置规则（对标 Zed `add_entry(is_dir, cx)` 的 parent directory 确定逻辑）：
    /// - 选中已展开目录：新建在其第一子条目之前（depth + 1，parentID = selectedID）
    /// - 选中文件或折叠目录：新建在其之后（同 depth，parentID = 父目录）
    /// - 无选中：插入末尾，parentID = root
    func beginCreate(_ kind: InlineEditSession.Kind, near selectedID: EntryID?) async {
        guard kind == .createFile || kind == .createFolder else { return }
        cancelEdit()

        let (parentID, insertIndex, depth) = computeInsertPosition(near: selectedID)

        let session = InlineEditSession(
            kind: kind,
            parentDirectoryID: parentID,
            targetEntryID: nil,
            placeholderIndex: insertIndex,
            draftName: ""
        )
        let placeholder = VisibleEntry.placeholder(depth: depth, parentID: parentID)
        visibleEntries.insert(placeholder, at: insertIndex)
        inlineEdit = session
        validationError = nil
    }

    /// 开始重命名指定条目（不插入占位行，直接切换 Cell 渲染）。
    ///
    /// 对标 Zed `rename_impl(selection, cx)`：设 `leaf_entry_id = Some(entry_id)`,
    /// editor text = `file_name`（当前文件名作为 draftName 初始值）。
    func beginRename(_ id: EntryID) async {
        cancelEdit()
        guard let targetEntry = visibleEntries.first(where: { $0.id == id }) else { return }

        let parentURL = id.url.deletingLastPathComponent()
        let parentID = EntryID(url: parentURL.standardizedFileURL)

        inlineEdit = InlineEditSession(
            kind: .rename,
            parentDirectoryID: parentID,
            targetEntryID: id,
            placeholderIndex: -1,
            draftName: targetEntry.name
        )
        validationError = nil
    }

    // MARK: - 内联编辑：提交 / 取消

    /// 提交当前编辑会话。
    ///
    /// 流程（对标 Zed `confirm_edit(refocus, cx)`）：
    /// 1. 校验 draftName → 失败则 validationError，early return（占位行保留）
    /// 2. 调 WorkspaceFileTreeOperations 写磁盘
    /// 3. store.refreshDirectory(parentURL) 刷新 actor 状态
    /// 4. visibleEntries = await store.computeVisibleEntries()
    /// 5. inlineEdit = nil
    func commitEdit() async {
        guard let session = inlineEdit else { return }
        let draft = session.draftName.trimmingCharacters(in: .whitespaces)

        // 校验（对标 Zed `populate_validation_error` 最终守卫）
        let siblings = await store.siblingNames(of: session.parentDirectoryID)
        if let error = session.validateDraftName(siblingNames: siblings) {
            validationError = error
            return
        }
        validationError = nil

        let parentURL = session.parentDirectoryID.url
        do {
            switch session.kind {
            case .createFile:
                _ = try WorkspaceFileTreeOperations.createFile(named: draft, in: parentURL)
            case .createFolder:
                _ = try WorkspaceFileTreeOperations.createDirectory(named: draft, in: parentURL)
            case .rename:
                guard let targetURL = session.targetEntryID?.url else { return }
                _ = try WorkspaceFileTreeOperations.renameItem(at: targetURL, to: draft)
            }
        } catch {
            validationError = .duplicateName(draft)
            return
        }

        // 刷新（对标 Zed `update_visible_entries` 在 confirm_edit 结束后调用）
        await store.refreshDirectory(parentURL)
        visibleEntries = await store.computeVisibleEntries()
        inlineEdit = nil
    }

    /// 取消当前编辑会话，移除占位行，清空状态。
    ///
    /// 对标 Zed `discard_edit_state(cx)`：`edit_state.take()` 后 `update_visible_entries`。
    func cancelEdit() {
        guard let session = inlineEdit else { return }
        if session.isNewEntry {
            visibleEntries.removeAll(where: { $0.id == .placeholderSentinel })
        }
        inlineEdit = nil
        validationError = nil
    }

    // MARK: - 内部辅助

    /// 根据选中条目计算占位行的插入位置、父目录 ID 和缩进深度。
    private func computeInsertPosition(
        near selectedID: EntryID?
    ) -> (parentID: EntryID, index: Int, depth: Int) {
        guard let selectedID,
              let idx = visibleEntries.firstIndex(where: { $0.id == selectedID })
        else {
            let rootURL = rootDirectory ?? URL(fileURLWithPath: "/")
            return (EntryID(url: rootURL.standardizedFileURL),
                    visibleEntries.endIndex, 0)
        }
        let selected = visibleEntries[idx]
        if selected.isDirectory && selected.isExpanded {
            return (selected.id, idx + 1, selected.depth + 1)
        } else {
            let parentURL = selected.id.url.deletingLastPathComponent()
            let parentID = EntryID(url: parentURL.standardizedFileURL)
            return (parentID, idx + 1, selected.depth)
        }
    }

    // MARK: - FT-R9: 拖放操作

    /// 移动多个条目到目标目录
    func moveEntries(_ sourceIDs: [EntryID], to destinationID: EntryID) async {
        let sourceURLs = sourceIDs.map(\.url)
        let destinationURL = destinationID.url

        // 计算受影响的父目录（用于刷新）
        let affectedParentURLs = Set(sourceURLs.map { $0.deletingLastPathComponent().standardizedFileURL })

        do {
            _ = try WorkspaceFileTreeOperations.moveItems(at: sourceURLs, to: destinationURL)
        } catch {
            errorMessage = error.localizedDescription
        }

        // 刷新所有受影响目录（源父目录 + 目标目录）
        let allDirIDs = (Array(affectedParentURLs) + [destinationURL])
            .map { EntryID(url: $0.standardizedFileURL) }
        await store.refreshMultipleDirectories(allDirIDs)
        visibleEntries = await store.computeVisibleEntries()
        storeSnapshot = await store.makeSnapshot()
    }

    /// 复制多个条目到目标目录（Option 拖动或外部文件拖入）
    func copyEntries(_ sourceIDs: [EntryID], to destinationID: EntryID) async {
        let sourceURLs = sourceIDs.map(\.url)
        let destinationURL = destinationID.url

        do {
            _ = try WorkspaceFileTreeOperations.copyItems(at: sourceURLs, to: destinationURL)
        } catch {
            errorMessage = error.localizedDescription
        }

        await store.refreshMultipleDirectories([destinationID])
        visibleEntries = await store.computeVisibleEntries()
        storeSnapshot = await store.makeSnapshot()
    }

    /// 外部文件拖入（URLs 来自 Finder 等），复制到目标目录
    func importExternalFiles(_ urls: [URL], to destinationID: EntryID) async {
        let destinationURL = destinationID.url

        do {
            _ = try WorkspaceFileTreeOperations.copyItems(at: urls, to: destinationURL)
        } catch {
            errorMessage = error.localizedDescription
        }

        await store.refreshMultipleDirectories([destinationID])
        visibleEntries = await store.computeVisibleEntries()
        storeSnapshot = await store.makeSnapshot()
    }

    /// 代理：展开目录（供 DnD hover-to-expand 调用）
    func expandDirectory(_ id: EntryID) async {
        do {
            try await store.expandDirectory(id)
        } catch {
            errorMessage = error.localizedDescription
        }
        visibleEntries = await store.computeVisibleEntries()
        storeSnapshot = await store.makeSnapshot()
    }
}
