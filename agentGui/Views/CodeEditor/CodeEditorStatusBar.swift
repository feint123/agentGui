import SwiftUI

struct CodeEditorStatusBar: View {
    let state: CodeEditorStatusBarState

    var body: some View {
        HStack(spacing: 12) {
            if state.selectionCount > 1 {
                Text("\(state.selectionCount) selections")
            } else {
                Text("Ln \(state.cursor.line)")
                Text("Col \(state.cursor.column)")
            }
            Text(state.languageLabel)
            Text(state.indentationText)
            Spacer(minLength: 12)
            Text(state.lspStateText)
            Text("E\(state.errorCount)")
            Text("W\(state.warningCount)")
        }
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(NSColor.windowBackgroundColor))
        .accessibilityIdentifier("codeEditor.statusBar")
        .accessibilityLabel(state.summaryText)
    }
}

extension CodeEditorStatusBarState {
    var indentationText: String {
        switch indentation.kind {
        case .spaces:
            return "Spaces: \(indentation.width)"
        case .tabs:
            return "Tabs: \(indentation.width)"
        case .unknown:
            return "Indent: unknown"
        }
    }

    var summaryText: String {
        let cursorInfo = selectionCount > 1
            ? "\(selectionCount) selections"
            : "Ln \(cursor.line) Col \(cursor.column)"
        return [
            cursorInfo,
            languageLabel,
            indentationText,
            lspStateText,
            "E\(errorCount)",
            "W\(warningCount)"
        ].joined(separator: " ")
    }
}