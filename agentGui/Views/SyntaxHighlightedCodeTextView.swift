import AppKit
import SwiftUI

struct SyntaxHighlightedCodeTextView: NSViewRepresentable {
    let attributedString: NSAttributedString
    var textInsets = NSSize(width: 12, height: 12)

    func makeNSView(context: Context) -> NSTextView {
        let textView = NSTextView(frame: .zero)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.textContainerInset = textInsets
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textStorage?.setAttributedString(attributedString)
        return textView
    }

    func updateNSView(_ nsView: NSTextView, context: Context) {
        nsView.textContainerInset = textInsets
        nsView.textStorage?.setAttributedString(attributedString)
        nsView.invalidateIntrinsicContentSize()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextView, context: Context) -> CGSize? {
        guard let textContainer = nsView.textContainer,
              let layoutManager = nsView.layoutManager else {
            return nil
        }

        textContainer.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        layoutManager.ensureLayout(for: textContainer)

        let usedRect = layoutManager.usedRect(for: textContainer)
        return CGSize(
            width: max(proposal.width ?? 0, ceil(usedRect.width + textInsets.width * 2)),
            height: ceil(usedRect.height + textInsets.height * 2)
        )
    }
}