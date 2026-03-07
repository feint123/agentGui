//
//  FileEditorView.swift
//  agentGui
//

import SwiftUI
import AppKit
import CodeEditSourceEditor
import CodeEditLanguages

/// 中间栏：文件编辑器，显示并可编辑当前在文件树中选中的文件
struct FileEditorView: View {

    // MARK: - Environment

    @Environment(WorkspaceState.self) private var workspaceState
    @Environment(\.colorScheme) private var colorScheme

    // MARK: - State

    /// Shared backing store. Passed once to SourceEditor; subsequent content
    /// changes via `replaceCharacters` propagate directly to the text view
    /// without any SwiftUI recreate cycle — avoiding the coordinator teardown
    /// race that caused the "index N is invalid" crash with `.id()`.
    @State private var textStorage = NSTextStorage()

    @State private var loadedFileURL: URL?
    /// Snapshot of the file content at last load/save; used for dirty detection.
    @State private var fileContent: String = ""
    @State private var errorMessage: String?
    @State private var isSaving = false
    @State private var language: CodeLanguage = .default
    @State private var editorState = SourceEditorState()
    @State private var hasUnsavedChanges: Bool = false

    private var theme: EditorTheme {
        colorScheme == .dark ? .dark : .light
    }

    // MARK: - Body

    var body: some View {
        Group {
            if let fileURL = workspaceState.selectedFile {
                editorView(for: fileURL)
            } else {
                emptyState
            }
        }
        .onChange(of: editorState) { _, _ in
            hasUnsavedChanges = loadedFileURL != nil && textStorage.string != fileContent
        }
        .onChange(of: workspaceState.selectedFile) { _, newURL in
            if let url = newURL {
                loadFile(url)
            } else {
                clearEditor()
            }
        }
        .alert("错误", isPresented: .constant(errorMessage != nil)) {
            Button("确定") { errorMessage = nil }
        } message: {
            if let msg = errorMessage { Text(msg) }
        }
    }

    // MARK: - Editor

    private func editorView(for url: URL) -> some View {
        VStack(spacing: 0) {
            // Title bar
            HStack(spacing: 6) {
                Image(systemName: "doc.text")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(url.lastPathComponent + (hasUnsavedChanges ? " •" : ""))
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    saveFile(url)
                } label: {
                    if isSaving {
                        ProgressView().scaleEffect(0.6).frame(width: 16, height: 16)
                    } else {
                        Image(systemName: "square.and.arrow.down")
                    }
                }
                .buttonStyle(.borderless)
                .disabled(!hasUnsavedChanges || isSaving)
                .help("保存 (⌘S)")
                .keyboardShortcut("s", modifiers: .command)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.bar)

            Divider()

            // SourceEditor backed by the shared NSTextStorage.
            // No .id() — content is updated via replaceCharacters, not by
            // recreating the view. Language changes are applied automatically
            // by updateNSViewController.
            SourceEditor(
                textStorage,
                language: language,
                configuration: SourceEditorConfiguration(
                    appearance: .init(
                        theme: theme,
                        font: .monospacedSystemFont(ofSize: 13, weight: .regular),
                        wrapLines: true
                    ),
                    behavior: .init(indentOption: .spaces(count: 4)),
                    peripherals: .init(showGutter: true, showMinimap: false)
                ),
                state: $editorState
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            if loadedFileURL != url {
                loadFile(url)
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        ContentUnavailableView {
            Label("未选择文件", systemImage: "doc.text")
        } description: {
            Text("从左侧文件树中单击文件来打开")
        }
    }

    // MARK: - File I/O

    private func loadFile(_ url: URL) {
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            if let t = try? String(contentsOf: url, encoding: .isoLatin1) {
                text = t
            } else {
                errorMessage = "无法读取文件：\(error.localizedDescription)"
                return
            }
        }

        // Replace text storage content directly; the text view updates
        // immediately because it is backed by this same storage object.
        textStorage.beginEditing()
        textStorage.replaceCharacters(
            in: NSRange(location: 0, length: textStorage.length),
            with: text
        )
        textStorage.endEditing()

        fileContent = text
        loadedFileURL = url
        language = CodeLanguage.detectLanguageFrom(url: url, prefixBuffer: String(text.prefix(500)))
        hasUnsavedChanges = false
        // nil cursor positions → makeNSViewController skips setCursorPositions entirely
        editorState = SourceEditorState()
    }

    private func clearEditor() {
        textStorage.beginEditing()
        textStorage.replaceCharacters(in: NSRange(location: 0, length: textStorage.length), with: "")
        textStorage.endEditing()
        fileContent = ""
        loadedFileURL = nil
        hasUnsavedChanges = false
    }

    private func saveFile(_ url: URL) {
        isSaving = true
        let textToSave = textStorage.string
        Task.detached(priority: .userInitiated) {
            do {
                try textToSave.write(to: url, atomically: true, encoding: .utf8)
                await MainActor.run {
                    self.fileContent = textToSave
                    self.hasUnsavedChanges = false
                    self.isSaving = false
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = "保存失败：\(error.localizedDescription)"
                    self.isSaving = false
                }
            }
        }
    }
}

// MARK: - EditorTheme system defaults

private extension EditorTheme {
    static var light: EditorTheme {
        EditorTheme(
            text: Attribute(color: rgb(0x000000)),
            insertionPoint: rgb(0x007AFF),
            invisibles: Attribute(color: rgb(0xD6D6D6)),
            background: rgb(0xFFFFFF),
            lineHighlight: rgb(0xECF5FF),
            selection: rgb(0xB2D7FF),
            keywords: Attribute(color: rgb(0x9B2393), bold: true),
            commands: Attribute(color: rgb(0x326D74)),
            types: Attribute(color: rgb(0x0B4F79)),
            attributes: Attribute(color: rgb(0x815F03)),
            variables: Attribute(color: rgb(0x0F68A0)),
            values: Attribute(color: rgb(0x6C36A9)),
            numbers: Attribute(color: rgb(0x1C00CF)),
            strings: Attribute(color: rgb(0xC41A16)),
            characters: Attribute(color: rgb(0x1C00CF)),
            comments: Attribute(color: rgb(0x267507))
        )
    }

    static var dark: EditorTheme {
        EditorTheme(
            text: Attribute(color: rgb(0xDFE1E8)),
            insertionPoint: rgb(0x007AFF),
            invisibles: Attribute(color: rgb(0x53606E)),
            background: rgb(0x292A30),
            lineHighlight: rgb(0x2F3239),
            selection: rgb(0x646F83),
            keywords: Attribute(color: rgb(0xFC5FA3), bold: true),
            commands: Attribute(color: rgb(0x67B7A4)),
            types: Attribute(color: rgb(0x5DD8FF)),
            attributes: Attribute(color: rgb(0xD9C97C)),
            variables: Attribute(color: rgb(0x5DD8FF)),
            values: Attribute(color: rgb(0xD0A8FF)),
            numbers: Attribute(color: rgb(0xD0BF69)),
            strings: Attribute(color: rgb(0xFF8170)),
            characters: Attribute(color: rgb(0xD0BF69)),
            comments: Attribute(color: rgb(0x6C7986))
        )
    }

    /// Create a concrete sRGB NSColor from a 0xRRGGBB hex value (no dynamic catalog lookup).
    private static func rgb(_ hex: Int) -> NSColor {
        NSColor(
            colorSpace: .sRGB,
            components: [
                CGFloat((hex >> 16) & 0xFF) / 255,
                CGFloat((hex >> 8) & 0xFF) / 255,
                CGFloat(hex & 0xFF) / 255,
                1.0
            ],
            count: 4
        )
    }
}

// MARK: - Preview

#Preview {
    FileEditorView()
        .environment(WorkspaceState())
        .frame(width: 400, height: 500)
}
