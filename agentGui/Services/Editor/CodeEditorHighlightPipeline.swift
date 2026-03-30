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

struct CodeEditorStyledLineFragment: @unchecked Sendable {
    let line: Int
    let utf16Range: NSRange
    let attributedString: NSAttributedString
    let fingerprint: Int
}

struct CodeEditorHighlightResult: @unchecked Sendable {
    let version: Int
    let lineRange: ClosedRange<Int>
    let lineFragments: [CodeEditorStyledLineFragment]
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
        max(document.lineCount, lineCount(in: request.retainedLineRange)) > realtimeHighlightLineLimit
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

        let lineFragments = makeLineFragments(
            for: request.retainedLineRange,
            replacementRange: replacementRange,
            highlighted: highlighted,
            document: document
        )

        return CodeEditorHighlightResult(
            version: request.version,
            lineRange: request.retainedLineRange,
            lineFragments: lineFragments
        )
    }

    private func makeLineFragments(
        for lineRange: ClosedRange<Int>,
        replacementRange: NSRange,
        highlighted: NSAttributedString,
        document: CodeEditorDocument
    ) -> [CodeEditorStyledLineFragment] {
        lineRange.compactMap { line in
            let documentLineRange = document.utf16LineRange(forLine: line)
            let fragmentRange = intersection(documentLineRange, replacementRange)
            guard fragmentRange.length > 0 else {
                return nil
            }

            let localRange = NSRange(
                location: fragmentRange.location - replacementRange.location,
                length: fragmentRange.length
            )
            let fragmentString = highlighted.attributedSubstring(from: localRange)

            return CodeEditorStyledLineFragment(
                line: line,
                utf16Range: fragmentRange,
                attributedString: fragmentString,
                fingerprint: stableFingerprint(
                    for: fragmentString,
                    line: line,
                    range: fragmentRange
                )
            )
        }
    }

    private func intersection(_ lhs: NSRange, _ rhs: NSRange) -> NSRange {
        let start = max(lhs.location, rhs.location)
        let end = min(lhs.upperBound, rhs.upperBound)
        guard end > start else {
            return NSRange(location: start, length: 0)
        }
        return NSRange(location: start, length: end - start)
    }

    private func stableFingerprint(
        for attributedString: NSAttributedString,
        line: Int,
        range: NSRange
    ) -> Int {
        var hasher = Hasher()
        hasher.combine(line)
        hasher.combine(range.location)
        hasher.combine(range.length)
        hasher.combine(attributedString.string)
        attributedString.enumerateAttributes(
            in: NSRange(location: 0, length: attributedString.length),
            options: []
        ) { attributes, subrange, _ in
            hasher.combine(subrange.location)
            hasher.combine(subrange.length)
            for key in attributes.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
                hasher.combine(key.rawValue)
                if let value = attributes[key] {
                    hasher.combine(String(describing: value))
                }
            }
        }
        return hasher.finalize()
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