import Foundation

enum WorkspaceFileTreeOperationError: LocalizedError, Equatable {
    case emptyName
    case invalidName
    case itemAlreadyExists
    case itemMissing

    var errorDescription: String? {
        switch self {
        case .emptyName:
            return "名称不能为空。"
        case .invalidName:
            return "名称不能包含路径分隔符。"
        case .itemAlreadyExists:
            return "目标已存在同名文件或文件夹。"
        case .itemMissing:
            return "目标不存在，可能已被外部修改。"
        }
    }
}

enum WorkspaceFileTreeOperations {
    static func createFile(named rawName: String, in directory: URL, contents: Data = Data()) throws -> URL {
        let destinationURL = try validatedDestinationURL(for: rawName, in: directory)
        guard FileManager.default.createFile(atPath: destinationURL.path, contents: contents) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return destinationURL
    }

    static func createDirectory(named rawName: String, in directory: URL) throws -> URL {
        let destinationURL = try validatedDestinationURL(for: rawName, in: directory)
        try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: false)
        return destinationURL
    }

    static func renameItem(at url: URL, to rawName: String) throws -> URL {
        let fileManager = FileManager.default
        let standardizedURL = url.standardizedFileURL
        guard fileManager.fileExists(atPath: standardizedURL.path) else {
            throw WorkspaceFileTreeOperationError.itemMissing
        }

        let destinationURL = try validatedDestinationURL(for: rawName, in: standardizedURL.deletingLastPathComponent())
        try fileManager.moveItem(at: standardizedURL, to: destinationURL)
        return destinationURL
    }

    static func deleteItem(at url: URL) throws {
        let standardizedURL = url.standardizedFileURL
        guard FileManager.default.fileExists(atPath: standardizedURL.path) else {
            throw WorkspaceFileTreeOperationError.itemMissing
        }
        try FileManager.default.removeItem(at: standardizedURL)
    }

    private static func validatedDestinationURL(for rawName: String, in directory: URL) throws -> URL {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw WorkspaceFileTreeOperationError.emptyName
        }
        guard !name.contains("/") && !name.contains(":") else {
            throw WorkspaceFileTreeOperationError.invalidName
        }

        let parentDirectory = directory.standardizedFileURL
        let destinationURL = parentDirectory.appending(path: name)
        guard !FileManager.default.fileExists(atPath: destinationURL.path) else {
            throw WorkspaceFileTreeOperationError.itemAlreadyExists
        }
        return destinationURL
    }
}