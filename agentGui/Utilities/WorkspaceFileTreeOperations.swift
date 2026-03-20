import Foundation

enum WorkspaceFileTreeOperationError: LocalizedError, Equatable {
    case emptyName
    case invalidName
    case itemAlreadyExists
    case itemMissing
    case invalidMoveDestination

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
        case .invalidMoveDestination:
            return "移动目标无效。"
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

        let trimmedName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName == standardizedURL.lastPathComponent {
            return standardizedURL
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

    static func moveItems(at urls: [URL], to destinationDirectory: URL) throws -> [URL] {
        let fileManager = FileManager.default
        let standardizedDestinationDirectory = destinationDirectory.standardizedFileURL
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: standardizedDestinationDirectory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw WorkspaceFileTreeOperationError.invalidMoveDestination
        }

        let uniqueSources = uniqueStandardizedURLs(urls)
        return try uniqueSources.map { sourceURL in
            let destinationURL = try validatedMoveDestination(for: sourceURL, to: standardizedDestinationDirectory)
            try fileManager.moveItem(at: sourceURL, to: destinationURL)
            return destinationURL
        }
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

    private static func validatedMoveDestination(for sourceURL: URL, to destinationDirectory: URL) throws -> URL {
        let standardizedSourceURL = sourceURL.standardizedFileURL
        guard FileManager.default.fileExists(atPath: standardizedSourceURL.path) else {
            throw WorkspaceFileTreeOperationError.itemMissing
        }

        let destinationDirectory = destinationDirectory.standardizedFileURL
        if destinationDirectory == standardizedSourceURL.deletingLastPathComponent().standardizedFileURL {
            throw WorkspaceFileTreeOperationError.invalidMoveDestination
        }
        if destinationDirectory.path.hasPrefix(standardizedSourceURL.path + "/") {
            throw WorkspaceFileTreeOperationError.invalidMoveDestination
        }

        let destinationURL = destinationDirectory.appending(path: standardizedSourceURL.lastPathComponent).standardizedFileURL
        guard destinationURL != standardizedSourceURL else {
            throw WorkspaceFileTreeOperationError.invalidMoveDestination
        }
        guard !FileManager.default.fileExists(atPath: destinationURL.path) else {
            throw WorkspaceFileTreeOperationError.itemAlreadyExists
        }
        return destinationURL
    }

    private static func uniqueStandardizedURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<URL>()
        var ordered: [URL] = []

        for url in urls.map(\.standardizedFileURL) {
            if seen.insert(url).inserted {
                ordered.append(url)
            }
        }

        return ordered
    }
}