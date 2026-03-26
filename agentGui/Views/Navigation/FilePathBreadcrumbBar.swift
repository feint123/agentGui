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

struct FilePathBreadcrumbBar<TrailingContent: View>: View {
    let iconSystemName: String?
    let items: [BreadcrumbNavigationItem]
    let onSelect: ((BreadcrumbNavigationItem) -> Void)?
    @ViewBuilder private let trailingContent: TrailingContent

    init(
        iconSystemName: String? = nil,
        items: [BreadcrumbNavigationItem],
        onSelect: ((BreadcrumbNavigationItem) -> Void)? = nil,
        @ViewBuilder trailingContent: () -> TrailingContent = { EmptyView() }
    ) {
        self.iconSystemName = iconSystemName
        self.items = items
        self.onSelect = onSelect
        self.trailingContent = trailingContent()
    }

    var body: some View {
        HStack(spacing: 6) {
            if let iconSystemName {
                Image(systemName: iconSystemName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ScrollView(.horizontal) {
                HStack(spacing: 4) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        if index > 0 {
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }

                        breadcrumbView(for: item)
                    }
                }
            }
            .scrollIndicators(.hidden)
            .frame(maxWidth: .infinity, alignment: .leading)

            trailingContent
        }
    }

    @ViewBuilder
    private func breadcrumbView(for item: BreadcrumbNavigationItem) -> some View {
        if let onSelect, !item.isCurrent {
            Button {
                onSelect(item)
            } label: {
                breadcrumbLabel(for: item)
            }
            .buttonStyle(.plain)
            .help(item.url?.path ?? item.title)
        } else {
            breadcrumbLabel(for: item)
                .help(item.url?.path ?? item.title)
        }
    }

    private func breadcrumbLabel(for item: BreadcrumbNavigationItem) -> some View {
        Text(item.title)
            .font(item.isCurrent ? .caption.weight(.medium) : .caption)
            .foregroundStyle(item.isCurrent ? .primary : .secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .fixedSize(horizontal: true, vertical: false)
    }
}