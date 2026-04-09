import AppKit

@MainActor
enum CodeEditorHighlightApplicator {
    static func apply(
        _ result: CodeEditorHighlightResult,
        decorations: CodeEditorDecorationSnapshot,
        to textView: NSTextView,
        baseAttributes: [NSAttributedString.Key: Any]
    ) -> Set<Int> {
        guard let storage = textView.textStorage else { return [] }
        let fragmentsByLine = Dictionary(uniqueKeysWithValues: result.lineFragments.map { ($0.line, $0) })
        let changedLines = changedLineSet(
            result: result,
            decorations: decorations,
            textView: textView
        )

        guard changedLines.isEmpty == false else {
            if let textView = textView as? CodeEditorPlatformTextView {
                updateFingerprints(result: result, decorations: decorations, textView: textView)
                textView.lastReappliedLines = []
            }
            return []
        }

        let selectedRange = textView.selectedRange()
        let typingAttributes = textView.typingAttributes

        storage.beginEditing()

        for line in changedLines.sorted() {
            guard let fragment = fragmentsByLine[line], fragment.utf16Range.upperBound <= storage.length else {
                continue
            }

            storage.setAttributes(baseAttributes, range: fragment.utf16Range)
            fragment.attributedString.enumerateAttributes(
                in: NSRange(location: 0, length: fragment.attributedString.length),
                options: []
            ) { attributes, range, _ in
                let targetRange = NSRange(
                    location: fragment.utf16Range.location + range.location,
                    length: range.length
                )
                storage.addAttributes(attributes, range: targetRange)
            }

            for span in decorations.spansByLine[line] ?? [] {
                let safeRange = clampedDecorationRange(span.utf16Range, storageLength: storage.length)
                guard safeRange.length > 0 else {
                    continue
                }
                storage.addAttributes(decorationAttributes(for: span.kind), range: safeRange)
            }
        }

        storage.endEditing()

        textView.setSelectedRange(selectedRange)
        textView.typingAttributes = typingAttributes

        if let textView = textView as? CodeEditorPlatformTextView {
            updateFingerprints(result: result, decorations: decorations, textView: textView)
            textView.lastReappliedLines = changedLines.sorted()
        }

        return changedLines
    }

    private static func changedLineSet(
        result: CodeEditorHighlightResult,
        decorations: CodeEditorDecorationSnapshot,
        textView: NSTextView
    ) -> Set<Int> {
        let newFingerprints = combinedFingerprints(result: result, decorations: decorations)
        guard let textView = textView as? CodeEditorPlatformTextView else {
            return Set(newFingerprints.keys)
        }

        return Set(newFingerprints.compactMap { line, fingerprint in
            textView.appliedLinePresentationFingerprints[line] == fingerprint ? nil : line
        })
    }

    private static func updateFingerprints(
        result: CodeEditorHighlightResult,
        decorations: CodeEditorDecorationSnapshot,
        textView: CodeEditorPlatformTextView
    ) {
        for (line, fingerprint) in combinedFingerprints(result: result, decorations: decorations) {
            textView.appliedLinePresentationFingerprints[line] = fingerprint
        }
    }

    private static func combinedFingerprints(
        result: CodeEditorHighlightResult,
        decorations: CodeEditorDecorationSnapshot
    ) -> [Int: Int] {
        let decorationFingerprints = decorationFingerprints(for: decorations)
        return Dictionary(uniqueKeysWithValues: result.lineFragments.map { fragment in
            let combined = fragment.fingerprint ^ (decorationFingerprints[fragment.line] ?? 0)
            return (fragment.line, combined)
        })
    }

    private static func decorationFingerprints(
        for decorations: CodeEditorDecorationSnapshot
    ) -> [Int: Int] {
        decorations.spansByLine.mapValues { spans in
            var hasher = Hasher()
            for span in spans.sorted(by: { lhs, rhs in
                if lhs.utf16Range.location == rhs.utf16Range.location {
                    return lhs.utf16Range.length < rhs.utf16Range.length
                }
                return lhs.utf16Range.location < rhs.utf16Range.location
            }) {
                hasher.combine(span.utf16Range.location)
                hasher.combine(span.utf16Range.length)
                hasher.combine(String(describing: span.kind))
            }
            return hasher.finalize()
        }
    }

    private static func clampedDecorationRange(_ range: NSRange, storageLength: Int) -> NSRange {
        let location = max(0, min(range.location, storageLength))
        let length = max(0, min(range.length, storageLength - location))
        return NSRange(location: location, length: length)
    }

    private static func decorationAttributes(
        for kind: CodeEditorDecorationKind
    ) -> [NSAttributedString.Key: Any] {
        switch kind {
        case .findMatch:
            return [.backgroundColor: NSColor.systemYellow.withAlphaComponent(0.28)]
        case .activeFindMatch:
            return [.backgroundColor: NSColor.systemOrange.withAlphaComponent(0.35)]
        case .selectionMatch:
            return [.backgroundColor: NSColor.selectedTextBackgroundColor.withAlphaComponent(0.18)]
        case let .diagnosticUnderline(severity):
            return [
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .underlineColor: underlineColor(for: severity)
            ]
        }
    }

    private static func underlineColor(for severity: LSPDiagnosticSeverity) -> NSColor {
        switch severity {
        case .error:
            return .systemRed
        case .warning:
            return .systemOrange
        case .information:
            return .systemBlue
        case .hint:
            return .systemGray
        }
    }
}
