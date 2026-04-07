import Foundation

struct FileNode: Identifiable, Hashable {
    let id: URL
    let name: String
    let isDirectory: Bool
    var children: [FileNode]?

    /// 目录加载状态。文件节点固定为 `.loaded`，目录节点初次构建时为 `.notLoaded`，
    /// 扫描完成后为 `.loaded`。
    enum ChildrenLoadState: Hashable {
        case notLoaded  // 目录，尚未扫描子项
        case loaded     // 已扫描（children 反映真实状态，可能为空 []）
    }
    var childrenLoadState: ChildrenLoadState

    // MARK: - 便捷初始化（保持向后兼容，childrenLoadState 有默认值）

    init(id: URL, name: String, isDirectory: Bool, children: [FileNode]?, childrenLoadState: ChildrenLoadState = .loaded) {
        self.id = id
        self.name = name
        self.isDirectory = isDirectory
        self.children = children
        self.childrenLoadState = childrenLoadState
    }
}

// MARK: - Hashable：仅由 id（URL）决定，childrenLoadState 不参与哈希/等价判断
// 这与 NSOutlineView 通过 id 追踪节点状态的方式一致。
extension FileNode {
    static func == (lhs: FileNode, rhs: FileNode) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

extension FileNode {
    var optionalChildren: [FileNode]? {
        guard isDirectory else { return nil }
        return children
    }
}