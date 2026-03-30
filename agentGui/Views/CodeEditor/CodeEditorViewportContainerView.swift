import AppKit

final class CodeEditorViewportContainerView: NSView {
    let gutterView: CodeEditorGutterView
    let scrollView: NSScrollView
    let textView: CodeEditorPlatformTextView

    override var isFlipped: Bool {
        true
    }

    init(scrollView: NSScrollView, textView: CodeEditorPlatformTextView) {
        self.scrollView = scrollView
        self.textView = textView
        self.gutterView = CodeEditorGutterView(textView: textView, lineCount: textView.displayedLineCount)
        super.init(frame: .zero)
        addSubview(gutterView)
        addSubview(scrollView)
        gutterView.onRequiredWidthChange = { [weak self] in
            self?.needsLayout = true
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()

        let gutterWidth = gutterView.requiredWidth
        gutterView.frame = NSRect(x: 0, y: 0, width: gutterWidth, height: bounds.height).integral
        scrollView.frame = NSRect(
            x: gutterWidth,
            y: 0,
            width: max(0, bounds.width - gutterWidth),
            height: bounds.height
        ).integral
    }
}