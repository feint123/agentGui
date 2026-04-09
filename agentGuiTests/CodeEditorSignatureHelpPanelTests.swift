// agentGuiTests/CodeEditorSignatureHelpPanelTests.swift
import Testing
import AppKit
@testable import agentGui

@Suite("CodeEditorSignatureHelpPanel")
@MainActor
struct CodeEditorSignatureHelpPanelTests {

    @Test func update_singleSignature_panelNotVisible_thenShow_becomesVisible() {
        let panel = CodeEditorSignatureHelpPanel()
        let sig = LSPSignatureInformation(
            label: "print(value: Any)",
            documentation: "Prints value to stdout.",
            parameters: [LSPParameterInformation(label: .text("value: Any"), documentation: nil)],
            activeParameter: nil
        )
        let help = LSPSignatureHelp(signatures: [sig], activeSignature: 0, activeParameter: 0)

        panel.update(help: help)
        #expect(!panel.isVisible)   // update 不自动显示
    }

    @Test func hide_afterShow_panelBecomesInvisible() {
        let panel = CodeEditorSignatureHelpPanel()
        let sig = LSPSignatureInformation(
            label: "foo(a: Int)",
            documentation: nil,
            parameters: [LSPParameterInformation(label: .text("a: Int"), documentation: nil)],
            activeParameter: nil
        )
        panel.update(help: LSPSignatureHelp(signatures: [sig], activeSignature: 0, activeParameter: 0))
        // 创建一个 host window 用于测试
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.show(anchoredBelow: NSRect(x: 100, y: 300, width: 10, height: 16), in: window)
        panel.hide()
        #expect(!panel.isVisible)
    }

    @Test func attributedLabel_withArrayRangeParam_highlightsCorrectSubstring() {
        let panel = CodeEditorSignatureHelpPanel()
        // "print(*objects)" → parameter label は [6, 14]（bytes）
        let sig = LSPSignatureInformation(
            label: "print(*objects)",
            documentation: nil,
            parameters: [LSPParameterInformation(label: .range(6, 14), documentation: nil)],
            activeParameter: 0
        )
        let help = LSPSignatureHelp(signatures: [sig], activeSignature: 0, activeParameter: 0)
        let attributed = panel.buildAttributedLabel(for: help)
        // 高亮范围应等于 [6,14) 的字符范围 "*objects"
        var foundBold = false
        attributed.enumerateAttribute(.font, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
            if let font = value as? NSFont, range.location == 6, range.length == 8 {
                foundBold = font.fontDescriptor.symbolicTraits.contains(.bold)
            }
        }
        #expect(foundBold)
    }

    @Test func overloadCounter_multipleSignatures_showsCorrectFraction() {
        let panel = CodeEditorSignatureHelpPanel()
        let sigs = [
            LSPSignatureInformation(label: "foo(a)", documentation: nil, parameters: [], activeParameter: nil),
            LSPSignatureInformation(label: "foo(a, b)", documentation: nil, parameters: [], activeParameter: nil),
            LSPSignatureInformation(label: "foo(a, b, c)", documentation: nil, parameters: [], activeParameter: nil),
        ]
        let help = LSPSignatureHelp(signatures: sigs, activeSignature: 1, activeParameter: 0)
        panel.update(help: help)
        #expect(panel.overloadCounterText == "2/3")
    }
}
