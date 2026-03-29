import AppKit
import Foundation

struct CodeEditorHighlightRequest: Equatable, Sendable {
    let version: Int
    let language: String?
    let visibleLineRange: ClosedRange<Int>
    let retainedLineRange: ClosedRange<Int>
    let dirtyLineRange: ClosedRange<Int>
    let priority: CodeEditorHighlightPriority
    let appearance: CodeHighlightAppearance
    let fontSize: CGFloat
}

enum CodeEditorHighlightPriority: Int, Sendable {
    case viewportImmediate
    case nearbyPrefetch
    case backgroundCatchUp
}

struct CodeEditorHighlightResult: @unchecked Sendable {
    let version: Int
    let lineRange: ClosedRange<Int>
    let replacementRange: NSRange
    let attributedString: NSAttributedString
}

struct CodeEditorHighlightPipeline {
    let retainedLinePadding: Int
    let realtimeHighlightLineLimit: Int

    init(retainedLinePadding: Int = 120, realtimeHighlightLineLimit: Int = 2_000) {
        self.retainedLinePadding = retainedLinePadding
        self.realtimeHighlightLineLimit = realtimeHighlightLineLimit
    }

    func makeViewportRequest(
        document: CodeEditorDocument,
        language: String?,
        visibleLineRange: ClosedRange<Int>,
        dirtyLineRange: ClosedRange<Int>,
        appearance: CodeHighlightAppearance,
        fontSize: CGFloat
    ) -> CodeEditorHighlightRequest {
        let lineCount = max(document.lineCount, 1)
        let lowerBound = max(1, visibleLineRange.lowerBound - retainedLinePadding)
        let upperBound = min(lineCount, visibleLineRange.upperBound + retainedLinePadding)

        return CodeEditorHighlightRequest(
            version: document.version,
            language: language,
            visibleLineRange: visibleLineRange,
            retainedLineRange: lowerBound...upperBound,
            dirtyLineRange: dirtyLineRange,
            priority: .viewportImmediate,
            appearance: appearance,
            fontSize: fontSize
        )
    }

    func shouldSkipRealtimeHighlight(
        for request: CodeEditorHighlightRequest,
        document: CodeEditorDocument
    ) -> Bool {
        lineCount(in: request.retainedLineRange) > realtimeHighlightLineLimit
    }

    func highlight(
        request: CodeEditorHighlightRequest,
        document: CodeEditorDocument,
        highlighter: any CodeSyntaxHighlighting
    ) -> CodeEditorHighlightResult? {
        guard request.version == document.version else {
            return nil
        }

        let replacementRange = requestedUTF16Range(for: request.retainedLineRange, document: document)
        let source = document.text as NSString
        let slice = source.substring(with: replacementRange)
        let highlighted = highlighter.highlightedString(
            code: slice,
            language: request.language,
            appearance: request.appearance,
            fontSize: request.fontSize
        )

        guard highlighted.length == replacementRange.length else {
            return nil
        }

        return CodeEditorHighlightResult(
            version: request.version,
            lineRange: request.retainedLineRange,
            replacementRange: replacementRange,
            attributedString: highlighted
        )
    }

    private func requestedUTF16Range(
        for lineRange: ClosedRange<Int>,
        document: CodeEditorDocument
    ) -> NSRange {
        let startOffset = document.lineIndex.lineStartOffset(forLine: lineRange.lowerBound)
        let endOffset: Int
        if lineRange.upperBound < document.lineCount {
            endOffset = max(
                startOffset,
                document.lineIndex.lineStartOffset(forLine: lineRange.upperBound + 1) - 1
            )
        } else {
            endOffset = document.text.utf16.count
        }

        return NSRange(location: startOffset, length: max(0, endOffset - startOffset))
    }

    private func lineCount(in lineRange: ClosedRange<Int>) -> Int {
        max(0, lineRange.upperBound - lineRange.lowerBound + 1)
    }
}