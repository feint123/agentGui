// agentGui/Views/FileTree/FileTreeInlineTextField.swift
import AppKit

/// 文件树内联编辑文本框（NSTextField 子类）。
///
/// 行为对标：
/// - VSCode `renderInputBox()` (explorerViewer.ts)：
///   Enter → done(true)，Escape → done(false)，blur → done(isInputValid)
/// - Zed `filename_editor` 订阅 `EditorEvent::Blurred`：失焦时调 `confirm_edit(false, cx)`
///
/// 使用者（`FileTreeCellView`）设置 `onCommit`、`onCancel`、`onValidate` 回调，
/// 并在适当时机调用 `beginEditing(initialText:selectStem:)` 聚焦。
final class FileTreeInlineTextField: NSTextField {

    /// 用户按 Return 且校验通过时调用（携带已 trim 的草稿名称）。
    var onCommit: (String) -> Void = { _ in }
    /// 用户按 Escape，或失焦时草稿为空/校验失败时调用。
    var onCancel: () -> Void = {}
    /// 每次文字变更时调用。返回 nil 表示合法；返回错误则显示行内提示。
    var onValidate: (String) -> EditValidationError? = { _ in nil }

    // 防止 controlTextDidEndEditing 被递归调用
    private var isHandlingEnd = false

    // MARK: - 初始化

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        isBordered = true
        isBezeled = true
        bezelStyle = .roundedBezel
        focusRingType = .none
        font = .systemFont(ofSize: NSFont.systemFontSize)
        controlSize = .small
        translatesAutoresizingMaskIntoConstraints = false
        delegate = self
    }

    // MARK: - 开始编辑

    /// 聚焦并设置初始文本，可选择性地只选中文件名主干（不含扩展名）。
    ///
    /// 对标 VSCode `renderInputBox()` 中：
    /// `inputBox.select({ start: 0, end: lastDot > 0 && !stat.isDirectory ? lastDot : value.length })`
    /// 以及 Zed `rename_impl` 中 `editor.select(0..stem_len, cx)`。
    func beginEditing(initialText: String, selectStem: Bool) {
        stringValue = initialText
        window?.makeFirstResponder(self)
        guard selectStem, let fieldEditor = currentEditor() as? NSTextView else { return }
        let stemEnd: Int
        if let dotRange = initialText.range(of: ".", options: .backwards),
           !initialText.hasPrefix(".") {
            stemEnd = initialText.distance(from: initialText.startIndex, to: dotRange.lowerBound)
        } else {
            stemEnd = initialText.utf16.count
        }
        fieldEditor.selectedRange = NSRange(location: 0, length: stemEnd)
    }

    // MARK: - 键盘处理

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36: // Return
            attemptCommit()
        case 53: // Escape
            onCancel()
        default:
            super.keyDown(with: event)
        }
    }

    private func attemptCommit() {
        let text = stringValue.trimmingCharacters(in: .whitespaces)
        if let error = onValidate(text) {
            showValidationError(error.errorDescription ?? "")
        } else {
            hideValidationError()
            onCommit(text)
        }
    }

    // MARK: - 行内校验错误提示

    private var errorLabel: NSTextField?

    private func showValidationError(_ message: String) {
        if errorLabel == nil {
            let label = NSTextField(labelWithString: "")
            label.textColor = .systemRed
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            label.translatesAutoresizingMaskIntoConstraints = false
            superview?.addSubview(label)
            if let superview {
                NSLayoutConstraint.activate([
                    label.topAnchor.constraint(equalTo: bottomAnchor, constant: 2),
                    label.leadingAnchor.constraint(equalTo: leadingAnchor),
                    label.trailingAnchor.constraint(lessThanOrEqualTo: superview.trailingAnchor,
                                                    constant: -4),
                ])
            }
            errorLabel = label
        }
        errorLabel?.stringValue = message
        errorLabel?.isHidden = false
    }

    private func hideValidationError() {
        errorLabel?.isHidden = true
    }
}

// MARK: - NSTextFieldDelegate

extension FileTreeInlineTextField: NSTextFieldDelegate {

    func controlTextDidChange(_ obj: Notification) {
        let text = (obj.object as? NSTextField)?.stringValue ?? ""
        if let error = onValidate(text) {
            showValidationError(error.errorDescription ?? "")
        } else {
            hideValidationError()
        }
    }

    /// 失焦时行为（对标 VSCode `done(inputBox.isInputValid(), true)` / Zed `confirm_edit(false, cx)`）：
    /// - 文本合法 → 提交
    /// - 文本非法（空或校验失败）→ 取消
    func controlTextDidEndEditing(_ obj: Notification) {
        guard !isHandlingEnd else { return }
        isHandlingEnd = true
        defer { isHandlingEnd = false }

        let text = stringValue.trimmingCharacters(in: .whitespaces)
        if !text.isEmpty, onValidate(text) == nil {
            onCommit(text)
        } else {
            onCancel()
        }
    }
}
