import CoreGraphics
import Testing
@testable import agentGui

struct ChatSurfaceLayoutMetricsTests {

    @Test func desktopConversationWidthUsesReadableProductRange() {
        #expect(ChatSurfaceLayoutMetrics.desktopConversationMaxWidth == 880)
    }

    @Test func proposalDockHeightCapsAtFourReviewRows() {
        #expect(ChatSurfaceLayoutMetrics.proposalDockMaxVisibleRows == 4)
        #expect(
            ChatSurfaceLayoutMetrics.proposalDockMaxHeight ==
            CGFloat(ChatSurfaceLayoutMetrics.proposalDockMaxVisibleRows) * ChatSurfaceLayoutMetrics.proposalDockEstimatedRowHeight
        )
    }

    @Test func composerHeightUsesSingleLineWhenComposerIsIdle() {
        let lineHeight: CGFloat = 18

        let height = ChatSurfaceLayoutMetrics.composerHeight(
            text: "",
            measuredTextHeight: lineHeight * 4,
            lineHeight: lineHeight
        )

        #expect(height == ChatSurfaceLayoutMetrics.composerHeight(forLineCount: 1, lineHeight: lineHeight))
    }

    @Test func composerHeightTracksWrappedContentUntilMaximumLineCount() {
        let lineHeight: CGFloat = 18

        let height = ChatSurfaceLayoutMetrics.composerHeight(
            text: "line 1\nline 2\nline 3",
            measuredTextHeight: lineHeight * 3,
            lineHeight: lineHeight
        )

        #expect(height == ChatSurfaceLayoutMetrics.composerHeight(forLineCount: 3, lineHeight: lineHeight))
    }

    @Test func composerHeightCapsGrowthAtTenLines() {
        let lineHeight: CGFloat = 18

        let height = ChatSurfaceLayoutMetrics.composerHeight(
            text: String(repeating: "wrapped ", count: 40),
            measuredTextHeight: lineHeight * 16,
            lineHeight: lineHeight
        )

        #expect(height == ChatSurfaceLayoutMetrics.composerHeight(forLineCount: 10, lineHeight: lineHeight))
    }
}