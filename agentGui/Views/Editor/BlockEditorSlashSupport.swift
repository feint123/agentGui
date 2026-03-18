import CoreGraphics
import Foundation

enum BlockSlashMenuCategoryID: String, Hashable, Identifiable {
    case currentBlock
    case basic
    case list
    case structure
    case table
    case resource

    var id: String { rawValue }
}

enum BlockSlashCommandAction: Equatable {
    case convertCurrent(DocumentBlockKind)
    case toggleTodoCompletion
    case collapseToggle
    case expandToggle
    case clearFormatting
    case deleteBlock
    case outdentBlock
    case indentBlock
    case createTablePreset(rows: Int, columns: Int)
}

struct BlockSlashCommandItem: Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String
    let symbolName: String
    let keywords: [String]
    let targetKind: DocumentBlockKind?
    let action: BlockSlashCommandAction

    func matches(query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        if title.localizedStandardContains(trimmed) || subtitle.localizedStandardContains(trimmed) {
            return true
        }
        return keywords.contains { $0.localizedStandardContains(trimmed) }
    }
}

struct BlockSlashCommandCategory: Identifiable, Equatable {
    let id: BlockSlashMenuCategoryID
    let title: String
    let symbolName: String
    let items: [BlockSlashCommandItem]
}

struct BlockEditorSlashContext: Equatable {
    let blockID: UUID
    let currentKind: DocumentBlockKind
    let match: BlockEditorSlashQueryParser.Match
    let anchorRect: CGRect

    var query: String { match.query }
    var tokenRange: NSRange { match.tokenRange }
}

struct BlockEditorSlashState: Equatable {
    enum NavigationOutcome: Equatable {
        case none
        case moved
        case openedCategory
        case collapsedCategory
    }

    var context: BlockEditorSlashContext?
    var categories: [BlockSlashCommandCategory] = []
    var highlightedCategoryID: BlockSlashMenuCategoryID?
    var selectedCategoryID: BlockSlashMenuCategoryID?
    var highlightedItemID: String?
    var scrollTargetItemID: String?

    var isPresented: Bool {
        context != nil
    }

    var selectedCategory: BlockSlashCommandCategory? {
        guard let selectedCategoryID else { return nil }
        return categories.first(where: { $0.id == selectedCategoryID })
    }

    var selectedItem: BlockSlashCommandItem? {
        guard let category = selectedCategory else { return nil }
        if let highlightedItemID,
           let item = category.items.first(where: { $0.id == highlightedItemID }) {
            return item
        }
        return category.items.first
    }

    mutating func update(context: BlockEditorSlashContext?, currentBlock: DocumentBlock?, registry: BlockSlashCommandRegistry) {
        guard let context, let currentBlock else {
            clear()
            return
        }

        self.context = context
        categories = registry.categories(for: currentBlock, query: context.query)

        if let highlightedCategoryID,
           categories.contains(where: { $0.id == highlightedCategoryID }) == false {
            self.highlightedCategoryID = nil
        }

        if highlightedCategoryID == nil {
            highlightedCategoryID = categories.first?.id
        }

        if let selectedCategoryID,
           categories.contains(where: { $0.id == selectedCategoryID }) == false {
            self.selectedCategoryID = nil
        }

        guard let category = selectedCategory else {
            highlightedItemID = nil
            return
        }

        if category.items.contains(where: { $0.id == highlightedItemID }) == false {
            highlightedItemID = category.items.first?.id
            scrollTargetItemID = highlightedItemID
        }
    }

    mutating func moveSelection(delta: Int) {
        guard selectedCategoryID != nil else {
            _ = moveCategorySelection(delta: delta)
            return
        }
        _ = moveItemSelection(delta: delta)
    }

    mutating func moveCategorySelection(delta: Int) -> NavigationOutcome {
        guard !categories.isEmpty else { return .none }
        let currentID = highlightedCategoryID ?? categories.first?.id
        guard let currentID,
              let currentIndex = categories.firstIndex(where: { $0.id == currentID }) else {
            highlightedCategoryID = categories.first?.id
            return .moved
        }

        let nextIndex = min(max(currentIndex + delta, 0), categories.count - 1)
        guard nextIndex != currentIndex else { return .none }
        highlightedCategoryID = categories[nextIndex].id
        return .moved
    }

    mutating func openHighlightedCategoryIfNeeded() -> NavigationOutcome {
        guard selectedCategoryID == nil else { return .none }
        guard let highlightedCategoryID else { return .none }
        selectedCategoryID = highlightedCategoryID
        highlightedItemID = selectedCategory?.items.first?.id
        scrollTargetItemID = highlightedItemID
        return .openedCategory
    }

    mutating func collapseCategorySelection() -> NavigationOutcome {
        guard selectedCategoryID != nil else { return .none }
        selectedCategoryID = nil
        highlightedItemID = nil
        scrollTargetItemID = nil
        return .collapsedCategory
    }

    mutating func moveItemSelection(delta: Int) -> NavigationOutcome {
        guard let category = selectedCategory, !category.items.isEmpty else { return .none }
        guard let highlightedItemID,
              let currentIndex = category.items.firstIndex(where: { $0.id == highlightedItemID }) else {
            self.highlightedItemID = category.items.first?.id
            scrollTargetItemID = self.highlightedItemID
            return .moved
        }

        let nextIndex = min(max(currentIndex + delta, 0), category.items.count - 1)
        guard nextIndex != currentIndex else { return .none }
        self.highlightedItemID = category.items[nextIndex].id
        scrollTargetItemID = self.highlightedItemID
        return .moved
    }

    mutating func selectCategory(_ id: BlockSlashMenuCategoryID) {
        highlightedCategoryID = id
        if selectedCategoryID == id {
            selectedCategoryID = nil
            highlightedItemID = nil
            scrollTargetItemID = nil
            return
        }
        selectedCategoryID = id
        highlightedItemID = selectedCategory?.items.first?.id
        scrollTargetItemID = highlightedItemID
    }

    mutating func openFirstCategoryIfNeeded() -> Bool {
        openHighlightedCategoryIfNeeded() == .openedCategory
    }

    mutating func consumeScrollTargetItemID() -> String? {
        defer { scrollTargetItemID = nil }
        return scrollTargetItemID
    }

    mutating func clear() {
        context = nil
        categories = []
        highlightedCategoryID = nil
        selectedCategoryID = nil
        highlightedItemID = nil
        scrollTargetItemID = nil
    }
}

enum BlockEditorFloatingOverlayLayout {
    static let menuCollapsedWidth: CGFloat = 172
    static let menuExpandedWidth: CGFloat = 420
    static let menuRowHeight: CGFloat = 38
    static let menuHeaderHeight: CGFloat = 44
    static let menuDividerHeight: CGFloat = 1
    static let menuMaxRows: CGFloat = 7
    static let menuColumnPadding: CGFloat = 12
    static let menuHorizontalMargin: CGFloat = 8
    static let menuVerticalMargin: CGFloat = 8

    static func slashMenuSize(categoryCount: Int, selectedItemCount: Int, isExpanded: Bool) -> CGSize {
        let visibleRows = max(selectedItemCount, categoryCount, 1)
        let columnHeight = min(CGFloat(visibleRows), menuMaxRows) * menuRowHeight + menuColumnPadding
        let width = isExpanded ? menuExpandedWidth : menuCollapsedWidth
        return CGSize(
            width: width,
            height: menuHeaderHeight + menuDividerHeight + columnHeight
        )
    }

    static func menuCenter(anchorRect: CGRect, viewportFrame: CGRect, contentHeight: CGFloat, menuSize: CGSize) -> CGPoint {
        let flippedAnchorY = contentHeight - anchorRect.maxY
        let rawX = anchorRect.midX - viewportFrame.minX + 12
        let rawY = flippedAnchorY - viewportFrame.minY + 8
        let halfWidth = menuSize.width / 2
        let minX = halfWidth + menuHorizontalMargin
        let maxX = max(minX, viewportFrame.width - halfWidth - menuHorizontalMargin)
        let minY = menuSize.height / 2
        let maxY = max(minY, viewportFrame.height - menuSize.height / 2 - menuVerticalMargin)

        return CGPoint(
            x: min(max(rawX, minX), maxX),
            y: min(max(rawY, minY), maxY)
        )
    }
}

struct BlockEditorSlashQueryParser {
    struct Match: Equatable {
        let rawToken: String
        let query: String
        let tokenRange: NSRange
    }

    static func detect(in text: String, selectedRange: NSRange) -> Match? {
        guard selectedRange.length == 0 else { return nil }

        let source = text as NSString
        let caretLocation = max(0, min(selectedRange.location, source.length))
        guard let tokenRange = tokenRange(in: text, caretLocation: caretLocation) else { return nil }

        let token = source.substring(with: tokenRange)
        guard token.hasPrefix("/") else { return nil }

        let query = String(token.dropFirst())
        guard !query.contains("/") else { return nil }
        return Match(rawToken: token, query: query, tokenRange: tokenRange)
    }

    static func removingToken(in text: String, tokenRange: NSRange) -> String {
        let source = text as NSString
        let safeLocation = max(0, min(tokenRange.location, source.length))
        let safeLength = max(0, min(tokenRange.length, source.length - safeLocation))
        let safeRange = NSRange(location: safeLocation, length: safeLength)

        guard safeRange.length > 0 else { return text }

        let updated = NSMutableString(string: text)
        updated.replaceCharacters(in: safeRange, with: "")

        if safeLocation > 0,
           safeLocation < updated.length,
           updated.character(at: safeLocation - 1).isWhitespace,
           updated.character(at: safeLocation).isWhitespace {
            updated.deleteCharacters(in: NSRange(location: safeLocation, length: 1))
        }

        return updated as String
    }

    private static func tokenRange(in text: String, caretLocation: Int) -> NSRange? {
        let source = text as NSString
        guard source.length > 0 else { return nil }

        let anchorLocation = max(0, min(max(caretLocation - 1, 0), source.length - 1))
        guard !source.character(at: anchorLocation).isWhitespace else { return nil }

        var start = anchorLocation
        while start > 0 && !source.character(at: start - 1).isWhitespace {
            start -= 1
        }

        var end = anchorLocation + 1
        while end < source.length && !source.character(at: end).isWhitespace {
            end += 1
        }

        let range = NSRange(location: start, length: end - start)
        guard range.length > 0 else { return nil }

        let token = source.substring(with: range)
        return token.hasPrefix("/") ? range : nil
    }
}

struct BlockSlashCommandRegistry {
    func categories(for block: DocumentBlock, query: String) -> [BlockSlashCommandCategory] {
        baseCategories(for: block).compactMap { category in
            let filteredItems = category.items.filter { $0.matches(query: query) }
            guard !filteredItems.isEmpty else { return nil }
            return BlockSlashCommandCategory(
                id: category.id,
                title: category.title,
                symbolName: category.symbolName,
                items: filteredItems
            )
        }
    }

    private func baseCategories(for block: DocumentBlock) -> [BlockSlashCommandCategory] {
        var categories: [BlockSlashCommandCategory] = []

        if let currentCategory = currentBlockCategory(for: block) {
            categories.append(currentCategory)
        }

        categories.append(
            category(
                id: .basic,
                title: "文本",
                symbolName: "text.alignleft",
                items: [.paragraph, .heading1, .heading2, .heading3, .quote, .callout, .toggle].map {
                    convertItem(to: $0, from: block.kind)
                }
            )
        )

        categories.append(
            category(
                id: .list,
                title: "列表",
                symbolName: "list.bullet",
                items: [.bulletedList, .numberedList, .todo].map {
                    convertItem(to: $0, from: block.kind)
                }
            )
        )

        categories.append(
            category(
                id: .structure,
                title: "结构",
                symbolName: "square.split.2x2",
                items: [.code, .source, .divider].map {
                    convertItem(to: $0, from: block.kind)
                }
            )
        )

        categories.append(
            category(
                id: .table,
                title: "表格",
                symbolName: "tablecells",
                items: [
                    tablePresetItem(rows: 2, columns: 2),
                    tablePresetItem(rows: 3, columns: 3),
                    tablePresetItem(rows: 4, columns: 4)
                ]
            )
        )

        categories.append(
            category(
                id: .resource,
                title: "资源",
                symbolName: "photo.on.rectangle",
                items: [.image, .url, .file].map {
                    convertItem(to: $0, from: block.kind)
                }
            )
        )

        return categories
    }

    private func currentBlockCategory(for block: DocumentBlock) -> BlockSlashCommandCategory? {
        var items: [BlockSlashCommandItem] = []

        switch block.kind {
        case .todo:
            items.append(
                BlockSlashCommandItem(
                    id: "current.todo.toggle",
                    title: block.metadata.checked ? "标记为未完成" : "标记为已完成",
                    subtitle: "切换当前待办的完成状态",
                    symbolName: block.metadata.checked ? "circle" : "checkmark.circle",
                    keywords: ["todo", "task", "完成", "待办"],
                    targetKind: nil,
                    action: .toggleTodoCompletion
                )
            )
        case .toggle:
            items.append(
                BlockSlashCommandItem(
                    id: block.metadata.isCollapsed ? "current.toggle.expand" : "current.toggle.collapse",
                    title: block.metadata.isCollapsed ? "展开折叠块" : "收起折叠块",
                    subtitle: "切换当前折叠块的展开状态",
                    symbolName: block.metadata.isCollapsed ? "chevron.down.circle" : "chevron.right.circle",
                    keywords: ["toggle", "details", "折叠", "展开"],
                    targetKind: nil,
                    action: block.metadata.isCollapsed ? .expandToggle : .collapseToggle
                )
            )
        default:
            break
        }

        items.append(
            BlockSlashCommandItem(
                id: "current.clearFormatting",
                title: "清除格式",
                subtitle: "重置为普通段落并移除当前块格式",
                symbolName: "textformat.clear",
                keywords: ["clear", "format", "plain", "格式", "段落"],
                targetKind: .paragraph,
                action: .clearFormatting
            )
        )

        items.append(
            BlockSlashCommandItem(
                id: "current.delete",
                title: "删除块",
                subtitle: "移除当前块并将焦点移动到相邻块",
                symbolName: "trash",
                keywords: ["delete", "remove", "trash", "删除", "块"],
                targetKind: nil,
                action: .deleteBlock
            )
        )

        if supportsIndentation(block.kind) {
            items.append(
                BlockSlashCommandItem(
                    id: "current.outdent",
                    title: "减少缩进",
                    subtitle: "提升当前块的层级",
                    symbolName: "decrease.indent",
                    keywords: ["outdent", "indent", "层级", "缩进"],
                    targetKind: nil,
                    action: .outdentBlock
                )
            )

            items.append(
                BlockSlashCommandItem(
                    id: "current.indent",
                    title: "增加缩进",
                    subtitle: "降低当前块的层级",
                    symbolName: "increase.indent",
                    keywords: ["indent", "层级", "缩进"],
                    targetKind: nil,
                    action: .indentBlock
                )
            )
        }

        guard !items.isEmpty else { return nil }
        return category(id: .currentBlock, title: "当前块", symbolName: block.kind.symbolName, items: items)
    }

    private func convertItem(to kind: DocumentBlockKind, from currentKind: DocumentBlockKind) -> BlockSlashCommandItem {
        BlockSlashCommandItem(
            id: "convert.\(kind.rawValue)",
            title: kind.title,
            subtitle: "将当前\(currentKind.title)转换为\(kind.title)",
            symbolName: kind.symbolName,
            keywords: kind.slashKeywords + [currentKind.title, "转换", "块"],
            targetKind: kind,
            action: .convertCurrent(kind)
        )
    }

    private func tablePresetItem(rows: Int, columns: Int) -> BlockSlashCommandItem {
        BlockSlashCommandItem(
            id: "table.\(rows)x\(columns)",
            title: "\(rows) x \(columns) 表格",
            subtitle: "快速创建 \(rows) 行 \(columns) 列的表格",
            symbolName: "tablecells",
            keywords: ["table", "grid", "表格", "\(rows)x\(columns)", "\(rows) 行", "\(columns) 列"],
            targetKind: .table,
            action: .createTablePreset(rows: rows, columns: columns)
        )
    }

    private func category(id: BlockSlashMenuCategoryID, title: String, symbolName: String, items: [BlockSlashCommandItem]) -> BlockSlashCommandCategory {
        BlockSlashCommandCategory(id: id, title: title, symbolName: symbolName, items: items)
    }

    private func supportsIndentation(_ kind: DocumentBlockKind) -> Bool {
        kind == .bulletedList || kind == .numberedList || kind == .todo || kind == .quote
    }
}

private extension unichar {
    var isWhitespace: Bool {
        guard let scalar = UnicodeScalar(Int(self)) else {
            return false
        }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }
}