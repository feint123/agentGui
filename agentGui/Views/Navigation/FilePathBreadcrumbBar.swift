import Foundation
import SwiftUI

struct BreadcrumbNavigationItem: Identifiable, Equatable {
    let id: String
    let title: String
    let url: URL?
    let isCurrent: Bool

    init(title: String, url: URL?, isCurrent: Bool) {
        self.title = title
        self.url = url?.standardizedFileURL
        self.isCurrent = isCurrent
        self.id = [self.url?.path, title, isCurrent ? "current" : "ancestor"]
            .compactMap { $0 }
            .joined(separator: "::")
    }
}

enum FilePathBreadcrumbs {
    static func makeItems(for fileURL: URL, relativeTo rootURL: URL? = nil) -> [BreadcrumbNavigationItem] {
        let normalizedFileURL = fileURL.standardizedFileURL

        if let rootURL,
           let items = makeRelativeItems(for: normalizedFileURL, rootURL: rootURL.standardizedFileURL) {
            return items
        }

        return makeAbsoluteItems(for: normalizedFileURL)
    }

    private static func makeRelativeItems(for fileURL: URL, rootURL: URL) -> [BreadcrumbNavigationItem]? {
        let filePath = fileURL.path
        let rootPath = rootURL.path

        guard filePath == rootPath || filePath.hasPrefix(rootPath + "/") else {
            return nil
        }

        let rootTitle = rootURL.lastPathComponent.isEmpty ? rootURL.path : rootURL.lastPathComponent
        var items = [BreadcrumbNavigationItem(title: rootTitle, url: rootURL, isCurrent: filePath == rootPath)]

        let relativePath = String(filePath.dropFirst(rootPath.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !relativePath.isEmpty else {
            return items
        }

        let components = relativePath.split(separator: "/").map(String.init)
        var currentURL = rootURL

        for (index, component) in components.enumerated() {
            let isCurrent = index == components.count - 1
            currentURL = isCurrent
                ? fileURL
                : currentURL.appending(path: component, directoryHint: .isDirectory).standardizedFileURL
            items.append(BreadcrumbNavigationItem(title: component, url: currentURL, isCurrent: isCurrent))
        }

        return items
    }

    private static func makeAbsoluteItems(for fileURL: URL) -> [BreadcrumbNavigationItem] {
        let components = fileURL.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        guard !components.isEmpty else {
            return [BreadcrumbNavigationItem(title: fileURL.path, url: fileURL, isCurrent: true)]
        }

        var currentPath = ""
        return components.enumerated().map { index, component in
            currentPath += "/" + component
            return BreadcrumbNavigationItem(
                title: component,
                url: URL(fileURLWithPath: currentPath).standardizedFileURL,
                isCurrent: index == components.count - 1
            )
        }
    }
}