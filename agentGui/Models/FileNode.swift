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

    // MARK: - Auto-fold (FT-U1)

    /// 折叠链各段名称。非空（count > 1）时表示该节点是一条压缩的单子目录链。
    /// 例如 src → src/main → src/main/java 压缩后为 ["src", "main", "java"]。
    /// 空数组表示普通目录节点。
    var foldedSegments: [String]

    /// 折叠链最内层目录的 URL，即实际存放子项的目录。
    /// 展开时 demandLoad 将扫描此 URL 而非 id（链头 URL）。
    var foldedTerminalURL: URL?

    // MARK: - 便捷初始化（保持向后兼容，childrenLoadState 有默认值）

    init(
        id: URL,
        name: String,
        isDirectory: Bool,
        children: [FileNode]?,
        childrenLoadState: ChildrenLoadState = .loaded,
        foldedSegments: [String] = [],
        foldedTerminalURL: URL? = nil
    ) {
        self.id = id
        self.name = name
        self.isDirectory = isDirectory
        self.children = children
        self.childrenLoadState = childrenLoadState
        self.foldedSegments = foldedSegments
        self.foldedTerminalURL = foldedTerminalURL
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

extension FileNode {
    // MARK: - Auto-fold helpers (FT-U1)

    /// 是否为压缩折叠节点：foldedSegments 包含超过 1 个段。
    var isFolded: Bool {
        foldedSegments.count > 1
    }

    /// 折叠路径显示字符串，各段以" / "拼接。普通节点返回 `name`。
    var foldDisplayPath: String {
        isFolded ? foldedSegments.joined(separator: " / ") : name
    }
}