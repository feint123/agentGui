// agentGui/Views/FileTree/FileTreeCellView.swift
import AppKit

/// 文件树行单元格。
/// 布局：[indentSpacer] [disclosureButton?] [icon(14pt)] [nameLabel] [gitBadge?]
///
/// 行高固定 22pt（VSCode ExplorerDelegate.ITEM_HEIGHT = 22，
/// Zed project_panel 中 uniform_list item_height）。
final class FileTreeCellView: NSTableCellView {

    static let reuseIdentifier = NSUserInterfaceItemIdentifier("fileTreeCell")

    // MARK: - 子视图

    private let indentSpacer = NSView()
    private let disclosureButton = NSButton()
    private let loadingSpinner: NSProgressIndicator = {
        let p = NSProgressIndicator()
        p.style = .spinning
        p.isIndeterminate = true
        p.controlSize = .small    // 16pt，与 disclosureButton 相同宽高
        p.isHidden = true
        p.translatesAutoresizingMaskIntoConstraints = false
        return p
    }()
    private let iconView = NSImageView()
    private let nameLabel = NSTextField()
    let gitBadgeLabel = NSTextField()
    /// 分段路径容器（仅 auto-fold 行使用，普通行隐藏）。
    /// 每个段是一个无边框 NSButton，段间插入弱色 " / " 标签。
    private let segmentedPathStack = NSStackView()
    private var segmentButtons: [(button: NSButton, entryID: EntryID)] = []

    // MARK: - 内部缓存

    private var indentWidthConstraint: NSLayoutConstraint?

    // MARK: - 回调

    /// 用户点击展开/折叠三角形时触发，传入对应 EntryID。
    var onToggleExpand: ((EntryID) -> Void)?

    /// 用户点击折叠路径的某个分段时触发，传入该段的 EntryID。
    /// 参考 Zed render_folder_elements + VSCode getIconLabelNameFromHTMLElement。
    var onUnfoldSegment: ((EntryID) -> Void)?

    // MARK: - 内部状态

    private var entryID: EntryID?

    // MARK: - 初始化

    override init(frame: NSRect) {
        super.init(frame: frame)
        buildLayout()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        buildLayout()
    }

    // MARK: - 构建布局

    private func buildLayout() {
        // indentSpacer：宽度由 depth 决定，高度撑满
        indentSpacer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(indentSpacer)

        // disclosureButton：仅目录显示，SF Symbol chevron
        disclosureButton.translatesAutoresizingMaskIntoConstraints = false
        disclosureButton.isBordered = false
        disclosureButton.imagePosition = .imageOnly
        disclosureButton.target = self
        disclosureButton.action = #selector(toggleTapped)
        addSubview(disclosureButton)
        addSubview(loadingSpinner)

        // iconView：14pt 文件图标
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(iconView)

        // nameLabel：只读文本
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.isBordered = false
        nameLabel.isEditable = false
        nameLabel.drawsBackground = false
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.cell?.truncatesLastVisibleLine = true
        addSubview(nameLabel)

        // gitBadgeLabel：右侧 git 状态字符
        gitBadgeLabel.translatesAutoresizingMaskIntoConstraints = false
        gitBadgeLabel.isBordered = false
        gitBadgeLabel.isEditable = false
        gitBadgeLabel.drawsBackground = false
        gitBadgeLabel.alignment = .right
        gitBadgeLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        addSubview(gitBadgeLabel)

        let indentWidth = indentSpacer.widthAnchor.constraint(equalToConstant: 0)
        indentWidthConstraint = indentWidth

        NSLayoutConstraint.activate([
            // 缩进占位（宽度通过 indentWidthConstraint.constant 动态设置）
            indentSpacer.leadingAnchor.constraint(equalTo: leadingAnchor),
            indentSpacer.topAnchor.constraint(equalTo: topAnchor),
            indentSpacer.bottomAnchor.constraint(equalTo: bottomAnchor),
            indentWidth,

            // 展开/折叠按钮：16×16
            disclosureButton.leadingAnchor.constraint(equalTo: indentSpacer.trailingAnchor),
            disclosureButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            disclosureButton.widthAnchor.constraint(equalToConstant: 16),
            disclosureButton.heightAnchor.constraint(equalToConstant: 16),

            // loadingSpinner：与 disclosureButton 完全重叠（spinner 替代展开箭头）
            // 参考 VSCode AsyncDataTreeRenderer.renderTwistie() ThemeIcon.Loading
            loadingSpinner.leadingAnchor.constraint(equalTo: disclosureButton.leadingAnchor),
            loadingSpinner.centerYAnchor.constraint(equalTo: disclosureButton.centerYAnchor),
            loadingSpinner.widthAnchor.constraint(equalToConstant: 16),
            loadingSpinner.heightAnchor.constraint(equalToConstant: 16),

            // 图标：14×14
            iconView.leadingAnchor.constraint(equalTo: disclosureButton.trailingAnchor, constant: 2),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 14),
            iconView.heightAnchor.constraint(equalToConstant: 14),

            // 文件名 label
            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 4),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            // git badge：固定宽度，右对齐
            gitBadgeLabel.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 4),
            gitBadgeLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            gitBadgeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            gitBadgeLabel.widthAnchor.constraint(equalToConstant: 20),
        ])

        // segmentedPathStack：与 nameLabel 同位置，初始隐藏
        segmentedPathStack.translatesAutoresizingMaskIntoConstraints = false
        segmentedPathStack.orientation = .horizontal
        segmentedPathStack.spacing = 0
        segmentedPathStack.isHidden = true
        addSubview(segmentedPathStack)
        NSLayoutConstraint.activate([
            segmentedPathStack.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            segmentedPathStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            segmentedPathStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
        ])
    }

    // MARK: - 配置

    /// 根据 VisibleEntry 配置本行外观。
    ///
    /// - Parameters:
    ///   - entry: 当前行数据
    ///   - isSelected: 是否处于选中状态
    ///   - onToggle: 展开/折叠回调（在 Coordinator 中绑定）
    ///   - onUnfoldSegment: 点击折叠路径某段时的回调（仅 auto-fold 行有效）
    func configure(
        entry: VisibleEntry,
        isSelected: Bool,
        onToggle: @escaping (EntryID) -> Void,
        onUnfoldSegment: ((EntryID) -> Void)? = nil
    ) {
        entryID = entry.id
        onToggleExpand = onToggle

        // 1. 缩进：depth * 16pt（与 Zed indent_size 一致）
        indentWidthConstraint?.constant = CGFloat(entry.depth) * 16

        // 2. 展开/折叠按钮 & loading spinner
        // 参考：
        //   Zed project_panel.rs `render_entry()` — `if details.is_dir_scanning { spinner } else { chevron }`
        //   VSCode asyncDataTree.ts `renderTwistie()` — `.slow` 状态显示 ThemeIcon.Loading
        if entry.isDirectory {
            switch entry.loadState {
            case .loading:
                // 扫描中：隐藏展开箭头，显示 spinner，禁用交互
                disclosureButton.isHidden = true
                disclosureButton.isEnabled = false
                loadingSpinner.isHidden = false
                loadingSpinner.startAnimation(nil)
            case .notLoaded, .loaded:
                // 正常状态：显示展开箭头，隐藏 spinner
                loadingSpinner.stopAnimation(nil)
                loadingSpinner.isHidden = true
                disclosureButton.isHidden = false
                disclosureButton.isEnabled = true
                let symbolName = entry.isExpanded ? "chevron.down" : "chevron.right"
                let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)
                disclosureButton.image = NSImage(systemSymbolName: symbolName,
                                                 accessibilityDescription: nil)?
                    .withSymbolConfiguration(config)
            }
        } else {
            loadingSpinner.stopAnimation(nil)
            loadingSpinner.isHidden = true
            disclosureButton.isHidden = true
            disclosureButton.isEnabled = true
        }

        // 3. 图标：复用 FileIconSymbolResolver
        let symbolName = FileIconSymbolResolver.symbol(forFileName: entry.name)
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        iconView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(symbolConfig)

        // 4. 名称 / 分段路径
        self.onUnfoldSegment = entry.foldedAncestors != nil ? onUnfoldSegment : nil
        if let folded = entry.foldedAncestors {
            nameLabel.isHidden = true
            configureSegmentedPath(folded, isSelected: isSelected)
        } else {
            segmentedPathStack.isHidden = true
            nameLabel.isHidden = false
            nameLabel.stringValue = entry.name
            nameLabel.textColor = isSelected ? .selectedMenuItemTextColor : .labelColor
        }

        // 5. git badge（FT-R7：区分文件/目录渲染）
        if let git = entry.gitSummary, !entry.isExpanded {
            gitBadgeLabel.isHidden = false
            if entry.isDirectory {
                // 折叠目录：彩点，半透明（参考 Zed Indicator::dot().color(...).opacity(0.5)）
                gitBadgeLabel.stringValue = "●"
                gitBadgeLabel.font = NSFont.systemFont(ofSize: 10)
                gitBadgeLabel.textColor = git.nsColor.withAlphaComponent(0.75)
            } else {
                // 文件：字母 badge，不透明
                gitBadgeLabel.stringValue = git.shortLabel
                gitBadgeLabel.font = NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize,
                                                                  weight: .medium)
                gitBadgeLabel.textColor = git.nsColor
            }
        } else {
            gitBadgeLabel.isHidden = true
            gitBadgeLabel.stringValue = ""
        }
    }

    // MARK: - 折叠路径渲染（FT-R5）

    /// 构建分段路径 StackView。每段一个无边框 NSButton，段间插入弱色 " / " 标签。
    /// 参考 Zed render_folder_elements + VSCode renderCompressedElements。
    private func configureSegmentedPath(_ folded: FoldedAncestors, isSelected: Bool) {
        segmentedPathStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        segmentButtons.removeAll()
        segmentedPathStack.isHidden = false

        let segColor: NSColor = isSelected ? .selectedMenuItemTextColor : .labelColor
        let sepColor: NSColor = isSelected ? .selectedMenuItemTextColor.withAlphaComponent(0.5)
                                            : .tertiaryLabelColor
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize(for: .regular))

        for (i, seg) in folded.segments.enumerated() {
            let btn = NSButton(title: seg.name, target: self, action: #selector(segmentTapped(_:)))
            btn.isBordered = false
            btn.font = font
            btn.contentTintColor = segColor
            btn.tag = i
            segmentedPathStack.addArrangedSubview(btn)
            segmentButtons.append((button: btn, entryID: seg.entryID))

            if i < folded.segments.count - 1 {
                let sep = NSTextField(labelWithString: " / ")
                sep.textColor = sepColor
                sep.font = font
                segmentedPathStack.addArrangedSubview(sep)
            }
        }
    }

    @objc private func segmentTapped(_ sender: NSButton) {
        let idx = sender.tag
        guard idx < segmentButtons.count else { return }
        onUnfoldSegment?(segmentButtons[idx].entryID)
    }

    // MARK: - 事件处理

    @objc private func toggleTapped() {
        guard let id = entryID else { return }
        onToggleExpand?(id)
    }
}

// MARK: - GitSummary 显示扩展

private extension GitSummary {
    /// 单字母 git 状态标记（对标 Zed git_status_indicator）
    var shortLabel: String {
        switch self {
        case .conflict:   return "!"
        case .untracked:  return "U"
        case .deleted:    return "D"
        case .modified:   return "M"
        case .staged:     return "S"
        case .added:      return "A"
        }
    }

    var nsColor: NSColor {
        switch self {
        case .conflict:           return .systemRed
        case .untracked, .added:  return .systemGreen
        case .deleted:            return .systemRed
        case .modified:           return .systemYellow
        case .staged:             return .systemBlue
        }
    }
}
