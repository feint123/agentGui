import CoreGraphics
import Foundation
import Testing
@testable import agentGui

@MainActor
@Suite(.serialized)
struct BlockEditorSlashCommandTests {

    @Test func detectsSlashQueryAtCaretInsideParagraph() async throws {
        let text = "hello /todo world"
        let caretLocation = (text as NSString).range(of: "/todo").location + 5

        let match = BlockEditorSlashQueryParser.detect(
            in: text,
            selectedRange: NSRange(location: caretLocation, length: 0)
        )

        #expect(match?.rawToken == "/todo")
        #expect(match?.query == "todo")
        #expect(match?.tokenRange == NSRange(location: 6, length: 5))
    }

    @Test func detectsSlashQueryWhenCaretSitsInsideToken() async throws {
        let text = "alpha /code beta"
        let caretLocation = (text as NSString).range(of: "/code").location + 2

        let match = BlockEditorSlashQueryParser.detect(
            in: text,
            selectedRange: NSRange(location: caretLocation, length: 0)
        )

        #expect(match?.rawToken == "/code")
        #expect(match?.query == "code")
    }

    @Test func ignoresAbsolutePathLikeSlashToken() async throws {
        let text = "open /Users/feint/project"
        let caretLocation = (text as NSString).range(of: "/Users/feint/project").location + 8

        let match = BlockEditorSlashQueryParser.detect(
            in: text,
            selectedRange: NSRange(location: caretLocation, length: 0)
        )

        #expect(match == nil)
    }

    @Test func paragraphMenuBuildsHierarchicalCategories() async throws {
        let registry = BlockSlashCommandRegistry()
        let block = DocumentBlock.empty(.paragraph)

        let categories = registry.categories(for: block, query: "")

        #expect(categories.map(\.id) == [.currentBlock, .basic, .list, .structure, .table, .resource])
        #expect(categories[1].items.map(\.targetKind) == [.paragraph, .heading1, .heading2, .heading3, .quote, .callout, .toggle])
        #expect(categories[2].items.map(\.targetKind) == [.bulletedList, .numberedList, .todo])
        #expect(categories[4].items.map(\.action) == [.createTablePreset(rows: 2, columns: 2), .createTablePreset(rows: 3, columns: 3), .createTablePreset(rows: 4, columns: 4)])
    }

    @Test func slashStateStartsWithCollapsedSecondaryMenu() async throws {
        let registry = BlockSlashCommandRegistry()
        let block = DocumentBlock.empty(.paragraph)
        let match = try #require(BlockEditorSlashQueryParser.detect(in: "/he", selectedRange: NSRange(location: 3, length: 0)))
        let context = BlockEditorSlashContext(
            blockID: UUID(),
            currentKind: block.kind,
            match: match,
            anchorRect: .zero
        )

        var state = BlockEditorSlashState()
        state.update(context: context, currentBlock: block, registry: registry)

        #expect(state.selectedCategoryID == nil)
        #expect(state.highlightedCategoryID == .basic)
        #expect(state.selectedCategory == nil)
        #expect(state.selectedItem == nil)
    }

    @Test func moveCategorySelectionCyclesCategoriesWhileCollapsed() async throws {
        let registry = BlockSlashCommandRegistry()
        let block = DocumentBlock.empty(.paragraph)
        let match = try #require(BlockEditorSlashQueryParser.detect(in: "/", selectedRange: NSRange(location: 1, length: 0)))
        let context = BlockEditorSlashContext(blockID: UUID(), currentKind: block.kind, match: match, anchorRect: .zero)

        var state = BlockEditorSlashState()
        state.update(context: context, currentBlock: block, registry: registry)
        #expect(state.moveCategorySelection(delta: 1) == .moved)

        #expect(state.selectedCategoryID == nil)
        #expect(state.highlightedCategoryID == .basic)
    }

    @Test func keyboardNavigationMovesAcrossCategoryLevels() async throws {
        let registry = BlockSlashCommandRegistry()
        let block = DocumentBlock.empty(.paragraph)
        let match = try #require(BlockEditorSlashQueryParser.detect(in: "/", selectedRange: NSRange(location: 1, length: 0)))
        let context = BlockEditorSlashContext(blockID: UUID(), currentKind: block.kind, match: match, anchorRect: .zero)

        var state = BlockEditorSlashState()
        state.update(context: context, currentBlock: block, registry: registry)

        #expect(state.openHighlightedCategoryIfNeeded() == .openedCategory)
        #expect(state.selectedCategoryID == .currentBlock)
        #expect(state.highlightedCategoryID == .currentBlock)
        #expect(state.highlightedItemID == state.selectedCategory?.items.first?.id)

        #expect(state.moveItemSelection(delta: 1) == .moved)
        #expect(state.scrollTargetItemID == state.selectedItem?.id)

        #expect(state.collapseCategorySelection() == .collapsedCategory)
        #expect(state.selectedCategoryID == nil)
        #expect(state.highlightedItemID == nil)
    }

    @Test func scrollTargetClearsWhenConsumed() async throws {
        var state = BlockEditorSlashState()
        state.scrollTargetItemID = "item-1"

        #expect(state.consumeScrollTargetItemID() == "item-1")
        #expect(state.consumeScrollTargetItemID() == nil)
    }

    @Test func floatingMenuCenterStaysInsideEditorBounds() async throws {
        let center = BlockEditorFloatingOverlayLayout.menuCenter(
            anchorRect: CGRect(x: 580, y: 320, width: 8, height: 20),
            viewportFrame: CGRect(x: 100, y: 100, width: 500, height: 600),
            contentHeight: 900,
            menuSize: CGSize(width: 420, height: 260)
        )

        #expect(center.x <= 500 - 210 - 8)
        #expect(center.x >= 210 + 8)
        #expect(center.y >= 130)
    }

    @Test func todoMenuIncludesBlockSpecificOperations() async throws {
        let registry = BlockSlashCommandRegistry()
        var block = DocumentBlock.empty(.todo)
        block.metadata.checked = false

        let categories = registry.categories(for: block, query: "")
        let currentCategory = try #require(categories.first)

        #expect(currentCategory.id == .currentBlock)
        #expect(currentCategory.items.map(\.action) == [.toggleTodoCompletion, .clearFormatting, .deleteBlock, .outdentBlock, .indentBlock])
    }

    @Test func queryFilteringPreservesOnlyMatchingCategoryBranches() async throws {
        let registry = BlockSlashCommandRegistry()
        let block = DocumentBlock.empty(.paragraph)

        let categories = registry.categories(for: block, query: "表格")

        #expect(categories.count == 1)
        #expect(categories.first?.id == .table)
        #expect(categories.first?.items.map(\.action) == [.createTablePreset(rows: 2, columns: 2), .createTablePreset(rows: 3, columns: 3), .createTablePreset(rows: 4, columns: 4)])
    }
}