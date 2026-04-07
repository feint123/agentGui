import AppKit

final class WorkspaceTreeNativeCellView: NSTableCellView, NSTextFieldDelegate {
    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let gitBadgeLabel = NSTextField(labelWithString: "")
    private let backgroundBox = NSBox()
    private var inlineField: InlineEditorTextField?
    private var hoverTrackingArea: NSTrackingArea?

    private var isRowSelected = false
    private var isRowHovered = false
    private var onInlineEditChange: ((String) -> Void)?
    private var onInlineEditCommit: (() -> Void)?
    private var onInlineEditCancel: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    private func setupViews() {
        backgroundBox.boxType = .custom
        backgroundBox.borderWidth = 0
        backgroundBox.cornerRadius = 5
        backgroundBox.fillColor = .clear
        backgroundBox.translatesAutoresizingMaskIntoConstraints = false
        addSubview(backgroundBox)

        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        addSubview(iconView)

        nameLabel.isEditable = false
        nameLabel.isBordered = false
        nameLabel.drawsBackground = false
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.font = .systemFont(ofSize: 12)
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(nameLabel)

        gitBadgeLabel.isEditable = false
        gitBadgeLabel.isBordered = false
        gitBadgeLabel.drawsBackground = false
        gitBadgeLabel.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
        gitBadgeLabel.translatesAutoresizingMaskIntoConstraints = false
        gitBadgeLabel.setContentHuggingPriority(.required, for: .horizontal)
        gitBadgeLabel.isHidden = true
        addSubview(gitBadgeLabel)

        NSLayoutConstraint.activate([
            backgroundBox.leadingAnchor.constraint(equalTo: leadingAnchor),
            backgroundBox.trailingAnchor.constraint(equalTo: trailingAnchor),
            backgroundBox.topAnchor.constraint(equalTo: topAnchor),
            backgroundBox.bottomAnchor.constraint(equalTo: bottomAnchor),

            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 14),
            iconView.heightAnchor.constraint(equalToConstant: 14),

            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 5),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: gitBadgeLabel.leadingAnchor, constant: -4),

            gitBadgeLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            gitBadgeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func configure(
        node: FileNode,
        isSelected: Bool,
        gitChange: GitFileChange?,
        isInlineEditing: Bool,
        draftName: String?,
        onInlineEditChange: @escaping (String) -> Void,
        onInlineEditCommit: @escaping () -> Void,
        onInlineEditCancel: @escaping () -> Void
    ) {
        isRowSelected = isSelected
        self.onInlineEditChange = onInlineEditChange
        self.onInlineEditCommit = onInlineEditCommit
        self.onInlineEditCancel = onInlineEditCancel

        // Icon
        let symbolName = node.isDirectory ? "folder.fill" : FileIconSymbolResolver.symbol(forFileName: node.name)
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        iconView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        iconView.contentTintColor = iconColor(for: node)

        // Inline editing vs static label
        if isInlineEditing {
            nameLabel.isHidden = true
            showInlineField(draftName: draftName ?? node.name)
        } else {
            nameLabel.isHidden = false
            hideInlineField()
            nameLabel.stringValue = node.foldDisplayPath
            nameLabel.textColor = isSelected ? .controlAccentColor : .labelColor
        }

        // Git badge
        if let gitChange {
            gitBadgeLabel.isHidden = false
            gitBadgeLabel.stringValue = gitBadgeText(for: gitChange.status)
            gitBadgeLabel.textColor = gitStatusNSColor(for: gitChange.status)
                .withAlphaComponent(isSelected || isRowHovered ? 1.0 : 0.72)
        } else {
            gitBadgeLabel.isHidden = true
        }

        updateBackground()

        setAccessibilityIdentifier(
            node.isDirectory ? "workspace.directory.\(node.name)" : "workspace.file.\(node.name)"
        )
    }

    // MARK: - Hover tracking

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = hoverTrackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isRowHovered = true
        updateBackground()
    }

    override func mouseExited(with event: NSEvent) {
        isRowHovered = false
        updateBackground()
    }

    // MARK: - NSTextFieldDelegate (inline edit)

    func controlTextDidChange(_ notification: Notification) {
        guard let textField = notification.object as? NSTextField else { return }
        onInlineEditChange?(textField.stringValue)
    }

    // MARK: - Private helpers

    private func updateBackground() {
        if isRowSelected {
            backgroundBox.fillColor = NSColor.controlAccentColor.withAlphaComponent(0.14)
        } else if isRowHovered {
            backgroundBox.fillColor = NSColor.labelColor.withAlphaComponent(0.07)
        } else {
            backgroundBox.fillColor = .clear
        }
    }

    private func iconColor(for node: FileNode) -> NSColor {
        if node.isDirectory {
            return isRowSelected ? .controlAccentColor : .systemOrange.withAlphaComponent(0.85)
        }
        return isRowSelected ? .controlAccentColor.withAlphaComponent(0.8) : .secondaryLabelColor
    }

    private func gitBadgeText(for status: GitChangeStatus) -> String {
        switch status {
        case .added: "A"
        case .modified: "M"
        case .deleted: "D"
        case .renamed: "R"
        case .untracked: "?"
        }
    }

    private func gitStatusNSColor(for status: GitChangeStatus) -> NSColor {
        switch status {
        case .added, .untracked: .systemGreen
        case .deleted: .systemRed
        case .renamed: .systemOrange
        case .modified: .secondaryLabelColor
        }
    }

    private func showInlineField(draftName: String) {
        if inlineField == nil {
            let field = InlineEditorTextField()
            field.isBordered = false
            field.drawsBackground = false
            field.focusRingType = .none
            field.font = .systemFont(ofSize: 12)
            field.lineBreakMode = .byTruncatingTail
            field.placeholderString = "输入名称"
            field.translatesAutoresizingMaskIntoConstraints = false
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            field.delegate = self
            addSubview(field)

            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 5),
                field.centerYAnchor.constraint(equalTo: centerYAnchor),
                field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            ])

            inlineField = field
        }

        inlineField?.isHidden = false
        if inlineField?.stringValue != draftName {
            inlineField?.stringValue = draftName
        }
        inlineField?.commitHandler = onInlineEditCommit
        inlineField?.cancelHandler = onInlineEditCancel

        DispatchQueue.main.async { [weak self] in
            self?.inlineField?.focusIfNeeded()
        }
    }

    private func hideInlineField() {
        inlineField?.isHidden = true
    }
}
