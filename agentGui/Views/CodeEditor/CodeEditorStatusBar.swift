import SwiftUI

struct CodeEditorStatusBar: View {
    let state: CodeEditorStatusBarState

    var body: some View {
        HStack(spacing: 12) {
            Text("Ln \(state.cursor.line)")
            Text("Col \(state.cursor.column)")
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
        [
            "Ln \(cursor.line)",
            "Col \(cursor.column)",
            languageLabel,
            indentationText,
            lspStateText,
            "E\(errorCount)",
            "W\(warningCount)"
        ].joined(separator: " ")
    }
}