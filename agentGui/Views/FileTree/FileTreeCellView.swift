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
    // FT-R8: 内联编辑文本框（与 nameLabel 同位置，初始隐藏）
    private let inlineTextField = FileTreeInlineTextField(frame: .zero)

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

        // FT-R8: 内联编辑文本框（覆盖在 nameLabel 位置，初始隐藏）
        inlineTextField.isHidden = true
        addSubview(inlineTextField)
        NSLayoutConstraint.activate([
            inlineTextField.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            inlineTextField.centerYAnchor.constraint(equalTo: centerYAnchor),
            inlineTextField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
        ])
    }

    // MARK: - 配置

    /// 根据 VisibleEntry 配置本行外观。
    ///
    /// - Parameters:
    ///   - entry: 当前行数据
    ///   - isSelected: 是否处于选中状态
    ///   - inlineEditSession: 当前内联编辑会话（nil = 非编辑态）
    ///   - onToggle: 展开/折叠回调（在 Coordinator 中绑定）
    ///   - onUnfoldSegment: 点击折叠路径某段时的回调（仅 auto-fold 行有效）
    ///   - onCommitEdit: 用户按 Return 提交编辑时回调
    ///   - onCancelEdit: 用户按 Esc 或失焦取消时回调
    ///   - onValidate: 实时校验回调
    func configure(
        entry: VisibleEntry,
        isSelected: Bool,
        inlineEditSession: InlineEditSession? = nil,
        onToggle: @escaping (EntryID) -> Void,
        onUnfoldSegment: ((EntryID) -> Void)? = nil,
        onCommitEdit: @escaping (String) -> Void = { _ in },
        onCancelEdit: @escaping () -> Void = {},
        onValidate: @escaping (String) -> EditValidationError? = { _ in nil }
    ) {
        entryID = entry.id
        onToggleExpand = onToggle

        // FT-R8: 编辑态检测（对标 VSCode renderElement → getEditableData 分支）
        let isEditing = entry.isEditPlaceholder
            || (inlineEditSession?.targetEntryID == entry.id)

        if isEditing {
            // 编辑态：隐藏 nameLabel，显示 inlineTextField
            nameLabel.isHidden = true
            segmentedPathStack.isHidden = true
            inlineTextField.isHidden = false

            inlineTextField.onCommit = onCommitEdit
            inlineTextField.onCancel = onCancelEdit
            inlineTextField.onValidate = onValidate

            // 重命名填当前文件名；新建留空（对标 VSCode renderInputBox 初始 value 逻辑）
            let initialText = (inlineEditSession?.targetEntryID != nil) ? entry.name : ""
            // 文件选主干，目录选全名（对标 VSCode lastDot > 0 && !stat.isDirectory 分支）
            inlineTextField.beginEditing(initialText: initialText,
                                         selectStem: !entry.isDirectory)

            // 仍需配置缩进和图标
            indentWidthConstraint?.constant = CGFloat(entry.depth) * 16
            disclosureButton.isHidden = true
            loadingSpinner.isHidden = true
            let editIconName = entry.isDirectory ? "folder" : FileIconSymbolResolver.symbol(forFileName: entry.name)
            let symbolConfig = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
            iconView.image = NSImage(systemSymbolName: editIconName,
                                     accessibilityDescription: nil)?
                .withSymbolConfiguration(symbolConfig)
            iconView.contentTintColor = entry.isDirectory ? .controlAccentColor : nil
            gitBadgeLabel.isHidden = true
            return
        }

        // 正常态：隐藏 inlineTextField
        inlineTextField.isHidden = true
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
                // 始终使用 chevron.right，通过旋转 transform 表达展开状态（带动画）
                // 对标 Zed `disclosure_control::<Disclosure>` 的 rotation animation
                // 以及 VSCode `twistie` 元素的 CSS `transform: rotate(90deg)` transition
                let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)
                disclosureButton.image = NSImage(systemSymbolName: "chevron.right",
                                                 accessibilityDescription: nil)?
                    .withSymbolConfiguration(config)
                let targetAngle: CGFloat = entry.isExpanded ? .pi / 2 : 0
                let currentAngle = disclosureButton.layer != nil
                    ? atan2(disclosureButton.layer!.transform.m12, disclosureButton.layer!.transform.m11)
                    : CGFloat(0)
                if abs(targetAngle - currentAngle) > 0.01 {
                    disclosureButton.wantsLayer = true
                    NSAnimationContext.runAnimationGroup { ctx in
                        ctx.duration = 0.15
                        ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                        disclosureButton.animator().layer?.transform = CATransform3DMakeRotation(targetAngle, 0, 0, 1)
                    }
                }
            }
        } else {
            loadingSpinner.stopAnimation(nil)
            loadingSpinner.isHidden = true
            disclosureButton.isHidden = true
            disclosureButton.isEnabled = true
        }

        // 3. 图标
        // 目录使用 folder / folder.fill（对标 Zed `FileAssociations::icon_for_type("dir")` 和
        // VSCode `ThemeIcon.Folder / ThemeIcon.FolderOpened`）。
        // 文件使用 FileIconSymbolResolver 按扩展名解析（对标 Zed language icon / VSCode seti-icon）。
        let iconSymbolName: String
        if entry.isDirectory {
            iconSymbolName = entry.isExpanded ? "folder.fill" : "folder"
        } else {
            iconSymbolName = FileIconSymbolResolver.symbol(forFileName: entry.name)
        }
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        iconView.image = NSImage(systemSymbolName: iconSymbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(symbolConfig)
        // 目录图标染色（对标 Zed 默认的 tab_bar_accent 蓝色文件夹）
        if entry.isDirectory {
            iconView.contentTintColor = .controlAccentColor
        } else {
            iconView.contentTintColor = nil
        }

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

    // MARK: - FT-R9: Auto-fold 段命中检测

    /// 给定拖拽位置（cell 坐标系），返回命中的折叠段索引和对应的 EntryID。
    /// 返回 nil 表示未命中任何折叠段（命中普通文件名区域或 indent spacer）。
    func hitTestFoldedSegment(at point: NSPoint) -> (segmentIndex: Int, entryID: EntryID)? {
        guard !segmentedPathStack.isHidden, !segmentButtons.isEmpty else { return nil }

        for (btn, entryID) in segmentButtons {
            // 将 button frame 从 segmentedPathStack 坐标转为 cell 坐标
            let btnFrameInCell = convert(btn.frame, from: segmentedPathStack)
            if btnFrameInCell.contains(point) {
                return (segmentIndex: btn.tag, entryID: entryID)
            }
        }
        return nil
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
