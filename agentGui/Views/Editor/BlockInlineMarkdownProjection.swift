import Foundation

struct BlockInlineMarkdownProjection: Equatable {
    let sourceText: String
    let hiddenMarkdownMarkerIndexes: IndexSet
    let visibleText: String

    init(sourceText: String) {
        self.sourceText = sourceText

        let hiddenRanges = BlockInlineMarkdownStyler.markerRanges(in: sourceText)
        self.hiddenMarkdownMarkerIndexes = hiddenRanges.reduce(into: IndexSet()) { result, range in
            result.insert(integersIn: range.location..<(range.location + range.length))
        }

        let nsSource = sourceText as NSString
        let visible = NSMutableString()
        var location = 0
        while location < nsSource.length {
            if hiddenMarkdownMarkerIndexes.contains(location) {
                location += 1
                continue
            }
            visible.append(nsSource.substring(with: NSRange(location: location, length: 1)))
            location += 1
        }
        self.visibleText = visible as String
    }

    func visibleOffset(forSourceUTF16Offset sourceOffset: Int) -> Int {
        let clamped = max(0, min(sourceOffset, sourceText.utf16.count))
        return clamped - hiddenMarkdownMarkerIndexes.count(in: 0..<clamped)
    }

    func sourceOffset(forVisibleUTF16Offset visibleOffset: Int) -> Int {
        let clamped = max(0, min(visibleOffset, visibleText.utf16.count))
        if clamped == visibleText.utf16.count {
            return sourceText.utf16.count
        }

        var visibleCount = 0
        var sourceOffset = 0
        while sourceOffset < sourceText.utf16.count {
            if hiddenMarkdownMarkerIndexes.contains(sourceOffset) {
                sourceOffset += 1
                continue
            }
            if visibleCount == clamped {
                return sourceOffset
            }
            visibleCount += 1
            sourceOffset += 1
        }
        return sourceText.utf16.count
    }

    func normalizedSourceOffset(for sourceOffset: Int) -> Int {
        let clamped = max(0, min(sourceOffset, sourceText.utf16.count))
        guard hiddenMarkdownMarkerIndexes.contains(clamped) else { return clamped }

        var cursor = clamped
        while hiddenMarkdownMarkerIndexes.contains(cursor), cursor < sourceText.utf16.count {
            cursor += 1
        }
        return min(cursor, sourceText.utf16.count)
    }

    func activeActions(in selectedRange: NSRange) -> Set<InlineStyleAction> {
        guard selectedRange.location != NSNotFound, selectedRange.length > 0 else { return [] }

        var actions = Set<InlineStyleAction>()
        append(action: .bold, matching: [.bold, .boldUnderscore], to: &actions, selectedRange: selectedRange)
        append(action: .italic, matching: [.italic, .italicUnderscore], to: &actions, selectedRange: selectedRange)
        append(action: .strikethrough, matching: [.strikethrough], to: &actions, selectedRange: selectedRange)
        append(action: .inlineCode, matching: [.code], to: &actions, selectedRange: selectedRange)
        return actions
    }

    private func append(action: InlineStyleAction, matching rules: [EditorInlineMarkdownRule], to actions: inout Set<InlineStyleAction>, selectedRange: NSRange) {
        for rule in rules {
            if rule.matches(in: sourceText).contains(where: { NSLocationInRange(selectedRange.location, $0.contentRange) && NSMaxRange(selectedRange) <= NSMaxRange($0.contentRange) }) {
                actions.insert(action)
                return
            }
        }
    }
}

private extension IndexSet {
    func count(in range: Range<Int>) -> Int {
        self.intersection(IndexSet(integersIn: range)).count
    }
}