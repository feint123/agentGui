import SwiftUI
import CoreGraphics
import Testing
@testable import agentGui

struct WorkbenchSidebarPanelStyleTests {

    @Test func sectionCardSupportsAccessoryContent() {
        let view = WorkbenchSidebarSectionCard(title: "状态", systemImage: "dot.radiowaves.left.and.right") {
            Text("内容")
        } accessory: {
            Text("运行中")
        }

        _ = view
        #expect(Bool(true))
    }

    @Test func tokensMatchSessionListBaselineDensity() {
        #expect(WorkbenchSidebarPanelStyle.layoutPadding == CGFloat(10))
        #expect(WorkbenchSidebarPanelStyle.headerBottomPadding == CGFloat(8))
        #expect(WorkbenchSidebarPanelStyle.controlCornerRadius == CGFloat(12))
        #expect(WorkbenchSidebarPanelStyle.cardCornerRadius == CGFloat(16))
        #expect(WorkbenchSidebarPanelStyle.compactSpacing == CGFloat(8))
        #expect(WorkbenchSidebarPanelStyle.sectionSpacing == CGFloat(10))
        #expect(WorkbenchSidebarPanelStyle.settingsRowSpacing == CGFloat(12))
        #expect(WorkbenchSidebarPanelStyle.settingsToggleColumnWidth == CGFloat(44))
    }
}