// agentGui/Views/CodeEditor/CodeEditorSignatureHelpPanel.swift

import AppKit

// MARK: - CodeEditorSignatureHelpPanel

/// NSPanel 签名帮助浮层。
/// 布局（从上到下）：
///   [overloads label]  [↑] [↓]
///   [signature attributed label]
///   [documentation label（可选）]
@MainActor
final class CodeEditorSignatureHelpPanel: NSObject {

    static let panelWidth: CGFloat = 420
    static let minPanelHeight: CGFloat = 32
    static let maxPanelHeight: CGFloat = 180

    // MARK: - Public state

    private(set) var isVisible: Bool = false
    private(set) var overloadCounterText: String = ""

    // MARK: - Callbacks

    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?

    // MARK: - Windowing

    let panel: NSPanel
    private let signatureLabel = NSTextField(labelWithString: "")
    private let docsLabel = NSTextField(wrappingLabelWithString: "")
    private let overloadsLabel = NSTextField(labelWithString: "")
    private let prevButton = NSButton(title: "↑", target: nil, action: nil)
    private let nextButton = NSButton(title: "↓", target: nil, action: nil)

    // MARK: - Init

    override init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: Self.minPanelHeight),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: true
        )
        super.init()
        setupPanel()
    }

    private func setupPanel() {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating

        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        container.layer?.cornerRadius = 6
        container.layer?.borderWidth = 1
        container.layer?.borderColor = NSColor.separatorColor.cgColor
        panel.contentView = container

        // override targets after super.init
        prevButton.target = self
        nextButton.target = self

        // overloads row
        overloadsLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        overloadsLabel.textColor = .secondaryLabelColor
        prevButton.bezelStyle = .inline
        prevButton.isBordered = false
        prevButton.font = NSFont.systemFont(ofSize: 11)
        nextButton.bezelStyle = .inline
        nextButton.isBordered = false
        nextButton.font = NSFont.systemFont(ofSize: 11)
        prevButton.action = #selector(didClickPrevious)
        nextButton.action = #selector(didClickNext)

        signatureLabel.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        signatureLabel.isEditable = false
        signatureLabel.isBordered = false
        signatureLabel.backgroundColor = .clear
        signatureLabel.lineBreakMode = .byTruncatingTail
        signatureLabel.maximumNumberOfLines = 2

        docsLabel.font = NSFont.systemFont(ofSize: 11)
        docsLabel.textColor = .secondaryLabelColor
        docsLabel.maximumNumberOfLines = 4

        [overloadsLabel, prevButton, nextButton, signatureLabel, docsLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview($0)
        }

        NSLayoutConstraint.activate([
            overloadsLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            overloadsLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),

            prevButton.centerYAnchor.constraint(equalTo: overloadsLabel.centerYAnchor),
            prevButton.leadingAnchor.constraint(equalTo: overloadsLabel.trailingAnchor, constant: 4),

            nextButton.centerYAnchor.constraint(equalTo: overloadsLabel.centerYAnchor),
            nextButton.leadingAnchor.constraint(equalTo: prevButton.trailingAnchor, constant: 2),

            signatureLabel.topAnchor.constraint(equalTo: overloadsLabel.bottomAnchor, constant: 4),
            signatureLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            signatureLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),

            docsLabel.topAnchor.constraint(equalTo: signatureLabel.bottomAnchor, constant: 4),
            docsLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            docsLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            docsLabel.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -6),
        ])
    }

    // MARK: - Public API

    func update(help: LSPSignatureHelp) {
        let multiple = help.signatures.count > 1
        overloadsLabel.isHidden = !multiple
        prevButton.isHidden = !multiple
        nextButton.isHidden = !multiple

        overloadsLabel.stringValue = multiple
            ? "\(help.activeSignature + 1)/\(help.signatures.count)"
            : ""
        overloadCounterText = overloadsLabel.stringValue

        let attributed = buildAttributedLabel(for: help)
        signatureLabel.attributedStringValue = attributed

        // docs
        let activeParam = help.resolvedActiveParameter(for: help.activeSignature)
        var docText = ""
        if let sig = help.activeSignatureInfo {
            if activeParam < sig.parameters.count,
               let paramDoc = sig.parameters[activeParam].documentation {
                docText = paramDoc
            } else if let sigDoc = sig.documentation {
                docText = sigDoc
            }
        }
        docsLabel.stringValue = docText
        docsLabel.isHidden = docText.isEmpty
    }

    func show(anchoredBelow cursorRect: NSRect, in window: NSWindow) {
        positionPanel(below: cursorRect, in: window)
        if !panel.isVisible {
            window.addChildWindow(panel, ordered: .above)
            panel.orderFront(nil)
        }
        isVisible = true
    }

    func hide() {
        guard panel.isVisible else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        isVisible = false
    }

    // MARK: - Attributed Label Building

    /// 构建签名高亮 AttributedString（高亮当前活跃参数，对标 VSCode renderParameters）
    func buildAttributedLabel(for help: LSPSignatureHelp) -> NSAttributedString {
        guard let sig = help.activeSignatureInfo else {
            return NSAttributedString(string: "")
        }
        let label = sig.label
        let activeParam = help.resolvedActiveParameter(for: help.activeSignature)

        let attributed = NSMutableAttributedString(string: label)
        let fullRange = NSRange(location: 0, length: (label as NSString).length)

        // 默认字体
        let normalFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let boldFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
        attributed.addAttribute(.font, value: normalFont, range: fullRange)
        attributed.addAttribute(.foregroundColor, value: NSColor.labelColor, range: fullRange)

        // 高亮当前参数
        if activeParam < sig.parameters.count {
            let param = sig.parameters[activeParam]
            let highlightRange = parameterLabelRange(param: param, in: label)
            if let r = highlightRange {
                attributed.addAttribute(.font, value: boldFont, range: r)
                attributed.addAttribute(.foregroundColor, value: NSColor.controlAccentColor, range: r)
            }
        }
        return attributed
    }

    // MARK: - Private

    private func parameterLabelRange(param: LSPParameterInformation, in label: String) -> NSRange? {
        let nsLabel = label as NSString
        switch param.label {
        case .range(let start, let end):
            // LSP 使用 UTF-16 偏移，需转换为 NSRange（NSString 也是 UTF-16）
            let length = end - start
            guard start >= 0, end <= nsLabel.length, length >= 0 else { return nil }
            return NSRange(location: start, length: length)
        case .text(let paramStr):
            let found = nsLabel.range(of: paramStr)
            return found.location == NSNotFound ? nil : found
        }
    }

    private func positionPanel(below cursorRect: NSRect, in window: NSWindow) {
        let screenRect = window.convertToScreen(cursorRect)
        let panelWidth = Self.panelWidth

        // 先测量内容高度
        panel.contentView?.layoutSubtreeIfNeeded()
        let idealHeight = min(
            max(panel.contentView?.fittingSize.height ?? Self.minPanelHeight, Self.minPanelHeight),
            Self.maxPanelHeight
        )

        var origin = NSPoint(
            x: screenRect.minX,
            y: screenRect.minY - idealHeight - 4
        )
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            if origin.y < frame.minY {
                // 空间不足，改为显示在光标上方
                origin.y = screenRect.maxY + 4
            }
            // 右边不超出屏幕
            if origin.x + panelWidth > frame.maxX {
                origin.x = frame.maxX - panelWidth - 8
            }
        }
        panel.setFrame(NSRect(x: origin.x, y: origin.y, width: panelWidth, height: idealHeight),
                       display: false)
    }

    @objc private func didClickPrevious() { onPrevious?() }
    @objc private func didClickNext() { onNext?() }
}
