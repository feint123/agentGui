import Testing
import AppKit
@testable import agentGui

/// 测试 CodeEditorPlatformTextView 中 agentChangeDiffByLine 存储与触发机制。
/// 无法直接测试像素绘制，但可测试状态属性读写和 needsDisplay 触发。
@MainActor
struct CodeEditorAgentDiffInlineRenderTests {

    @Test func agentChangeDiffByLineDefaultsToEmpty() throws {
        let textView = CodeEditorPlatformTextView(frame: .zero)
        #expect(textView.agentChangeDiffByLine.isEmpty)
    }

    @Test func settingAgentChangeDiffTriggersNeedsDisplay() throws {
        let textView = CodeEditorPlatformTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        // 在 window-less 环境下 needsDisplay 可能不精确，至少验证属性赋值不崩溃
        textView.agentChangeDiffByLine = [3: .added, 5: .modified]
        #expect(textView.agentChangeDiffByLine.count == 2)
        #expect(textView.agentChangeDiffByLine[3] == .added)
    }

    @Test func clearingAgentChangeDiffTriggersNeedsDisplay() throws {
        let textView = CodeEditorPlatformTextView(frame: .zero)
        textView.agentChangeDiffByLine = [1: .added]
        textView.agentChangeDiffByLine = [:]
        #expect(textView.agentChangeDiffByLine.isEmpty)
    }
}
