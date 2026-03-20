import Foundation

struct FileNode: Identifiable, Hashable {
    let id: URL
    let name: String
    let isDirectory: Bool
    var children: [FileNode]?
}

extension FileNode {
    var optionalChildren: [FileNode]? {
        guard isDirectory else { return nil }
        return children
    }
}