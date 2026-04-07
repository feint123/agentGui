import AppKit

final class CodeEditorViewportContainerView: NSView {
    let gutterView: CodeEditorGutterView
    let scrollView: NSScrollView
    let textView: CodeEditorPlatformTextView
    private var scrollObserver: NSObjectProtocol?

    override var isFlipped: Bool {
        true
    }

    init(scrollView: NSScrollView, textView: CodeEditorPlatformTextView) {
        self.scrollView = scrollView
        self.textView = textView
        self.gutterView = CodeEditorGutterView(lineCount: textView.displayedLineCount)
        super.init(frame: .zero)
        gutterView.clipsToBounds = true
        addSubview(gutterView)
        addSubview(scrollView)
        gutterView.onRequiredWidthChange = { [weak self] in
            self?.needsLayout = true
        }
        installGutterScrollSync()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let scrollObserver {
            NotificationCenter.default.removeObserver(scrollObserver)
        }
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
        syncGutterBoundsOrigin()
    }

    // MARK: - Gutter Scroll Sync

    /// Observe the scroll view's clip view bounds changes and mirror the
    /// vertical scroll offset into the gutter's bounds origin.  This keeps
    /// the gutter line positions in document coordinates while displaying
    /// only the visible portion – identical to how NSRulerView works.
    private func installGutterScrollSync() {
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: nil
        ) { [weak self] _ in
            self?.syncGutterBoundsOrigin()
        }
    }

    private func syncGutterBoundsOrigin() {
        let scrollY = scrollView.contentView.bounds.origin.y
        if gutterView.bounds.origin.y != scrollY {
            gutterView.setBoundsOrigin(NSPoint(x: 0, y: scrollY))
            gutterView.needsDisplay = true
        }
    }
}