import AppKit
import Foundation

struct TerminalRenderedRun: Equatable {
    var text: String
    var foregroundColor: NSColor?
    var backgroundColor: NSColor?
    var attributes: Set<TerminalTextAttribute>
}

struct TerminalRenderedScreen {
    var runs: [TerminalRenderedRun]
    var attributedString: NSAttributedString
    var plainText: String
    var backgroundColor: NSColor
    var hasStyledRuns: Bool
}

struct TerminalScreenRenderer {
    let theme: TerminalScreenTheme

    func render(_ snapshot: TerminalScreenSnapshot) -> TerminalRenderedScreen {
        let lines = snapshot.lines.isEmpty
            ? snapshot.plainTextLines.map { TerminalScreenLine(cells: $0.map { TerminalScreenCell(text: String($0)) }) }
            : snapshot.lines

        let renderedRuns = buildRuns(from: lines)
        let attributedString = NSMutableAttributedString()

        for run in renderedRuns {
            attributedString.append(NSAttributedString(string: run.text, attributes: textAttributes(for: run)))
        }

        return TerminalRenderedScreen(
            runs: renderedRuns,
            attributedString: attributedString,
            plainText: attributedString.string,
            backgroundColor: theme.defaultBackgroundColor,
            hasStyledRuns: renderedRuns.contains(where: { !$0.attributes.isEmpty || $0.backgroundColor != nil || $0.foregroundColor != nil })
        )
    }

    private func buildRuns(from lines: [TerminalScreenLine]) -> [TerminalRenderedRun] {
        var runs: [TerminalRenderedRun] = []

        for lineIndex in lines.indices {
            let cells = lines[lineIndex].cells.filter { !$0.isContinuationCell }
            if cells.isEmpty {
                runs.append(TerminalRenderedRun(text: lineIndex == lines.indices.last ? "" : "\n", foregroundColor: nil, backgroundColor: nil, attributes: []))
                continue
            }

            for cell in cells {
                let style = resolvedStyle(for: cell)
                if let last = runs.last,
                   last.foregroundColor?.isEqual(style.foregroundColor) ?? (style.foregroundColor == nil),
                   last.backgroundColor?.isEqual(style.backgroundColor) ?? (style.backgroundColor == nil),
                   last.attributes == cell.attributes,
                   last.text != "\n" {
                    runs[runs.count - 1].text += cell.text
                } else {
                    runs.append(TerminalRenderedRun(
                        text: cell.text,
                        foregroundColor: style.foregroundColor,
                        backgroundColor: style.backgroundColor,
                        attributes: cell.attributes
                    ))
                }
            }

            if lineIndex != lines.indices.last {
                runs.append(TerminalRenderedRun(text: "\n", foregroundColor: nil, backgroundColor: nil, attributes: []))
            }
        }

        if runs.isEmpty {
            runs = [TerminalRenderedRun(text: "", foregroundColor: nil, backgroundColor: nil, attributes: [])]
        }

        return runs
    }

    private func resolvedStyle(for cell: TerminalScreenCell) -> (foregroundColor: NSColor?, backgroundColor: NSColor?) {
        var foreground = theme.resolve(cell.foreground, fallback: theme.defaultForegroundColor)
        var background = theme.resolve(cell.background, fallback: theme.defaultBackgroundColor)

        if cell.attributes.contains(.inverse) {
            swap(&foreground, &background)
        }

        let hasForeground = cell.foreground != .defaultForeground || cell.attributes.contains(.inverse)
        let hasBackground = cell.background != .defaultBackground || cell.attributes.contains(.inverse)

        return (
            foregroundColor: hasForeground ? foreground : nil,
            backgroundColor: hasBackground ? background : nil
        )
    }

    private func textAttributes(for run: TerminalRenderedRun) -> [NSAttributedString.Key: Any] {
        var traits: NSFontDescriptor.SymbolicTraits = []
        if run.attributes.contains(.bold) {
            traits.insert(.bold)
        }
        if run.attributes.contains(.italic) {
            traits.insert(.italic)
        }

        let baseDescriptor = NSFont.monospacedSystemFont(ofSize: 11, weight: run.attributes.contains(.bold) ? .semibold : .regular).fontDescriptor
        let descriptor = baseDescriptor.withSymbolicTraits(traits) ?? baseDescriptor
        let font = NSFont(descriptor: descriptor, size: 11) ?? NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: run.foregroundColor ?? theme.defaultForegroundColor
        ]

        if let backgroundColor = run.backgroundColor {
            attributes[.backgroundColor] = backgroundColor
        }
        if run.attributes.contains(.underline) {
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        if run.attributes.contains(.strikethrough) {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }

        return attributes
    }
}