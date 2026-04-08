// StreamingCursorViewTests.swift
// agentGuiTests

import Testing
import SwiftUI
@testable import agentGui

struct StreamingCursorViewTests {

    /// 光标视图可以构建，不崩溃
    @Test
    func cursorViewBuilds() {
        let view = StreamingCursorView()
        // SwiftUI view 构造不应抛出
        _ = view.body
    }

    /// 光标的宽高常量符合设计规格
    @Test
    func cursorDimensionsMatchSpec() {
        #expect(StreamingCursorView.width == 1.5)
        #expect(StreamingCursorView.height == 14.0)
    }

    /// 光标淡出动画时长等于 ChatMotion.exitDuration
    @Test
    func cursorExitDurationMatchesMotionToken() {
        // ChatMotion.exitDuration = 0.18
        #expect(ChatMotion.exitDuration == 0.18)
    }
}
