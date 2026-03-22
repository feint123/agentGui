import CoreGraphics

enum ChatSurfaceLayoutMetrics {
    static let desktopConversationMaxWidth: CGFloat = 880
    static let proposalDockMaxVisibleRows = 4
    static let proposalDockEstimatedRowHeight: CGFloat = 62
    static let proposalDockMaxHeight: CGFloat = CGFloat(proposalDockMaxVisibleRows) * proposalDockEstimatedRowHeight
    static let composerMinimumLineCount = 1
    static let composerMaximumLineCount = 10
    static let composerTextContainerVerticalInset: CGFloat = 3
    static let composerHeightChromePadding: CGFloat = 4
    static let composerFallbackLineHeight: CGFloat = 16
    static let composerDefaultHeight = composerHeight(
        forLineCount: composerMinimumLineCount,
        lineHeight: composerFallbackLineHeight
    )

    static func composerHeight(forLineCount lineCount: Int, lineHeight: CGFloat) -> CGFloat {
        let clampedLineCount = max(lineCount, composerMinimumLineCount)
        return ceil(
            CGFloat(clampedLineCount) * lineHeight +
            composerTextContainerVerticalInset * 2 +
            composerHeightChromePadding
        )
    }

    static func composerHeight(text: String, measuredTextHeight: CGFloat, lineHeight: CGFloat) -> CGFloat {
        let minimumHeight = composerHeight(
            forLineCount: composerMinimumLineCount,
            lineHeight: lineHeight
        )
        guard !text.isEmpty else {
            return minimumHeight
        }

        let maximumHeight = composerHeight(
            forLineCount: composerMaximumLineCount,
            lineHeight: lineHeight
        )
        let measuredHeight = ceil(
            measuredTextHeight +
            composerTextContainerVerticalInset * 2 +
            composerHeightChromePadding
        )
        return min(max(measuredHeight, minimumHeight), maximumHeight)
    }
}