//
//  FileEditorView.swift
//  agentGui
//

import SwiftUI

/// 中间栏：文件编辑器，显示并可编辑当前在文件树中选中的文件
struct FileEditorView: View {

    // MARK: - Environment

    @Environment(WorkspaceState.self) private var workspaceState

    // MARK: - State

    @State private var content: String = ""
    @State private var loadedFileURL: URL?
    @State private var hasUnsavedChanges = false
    @State private var errorMessage: String?
    @State private var isSaving = false

    // MARK: - Body

    var body: some View {
        Group {
            if let fileURL = workspaceState.selectedFile {
                editorView(for: fileURL)
            } else {
                emptyState
            }
        }
        .onChange(of: workspaceState.selectedFile) { _, newURL in
            if let url = newURL {
                loadFile(url)
            } else {
                content = ""
                loadedFileURL = nil
                hasUnsavedChanges = false
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

            // Editor body
            TextEditor(text: Binding(
                get: { content },
                set: { newValue in
                    content = newValue
                    hasUnsavedChanges = true
                }
            ))
            .font(.system(.body, design: .monospaced))
            .scrollContentBackground(.hidden)
            .background(.background)
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
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            content = text
            loadedFileURL = url
            hasUnsavedChanges = false
        } catch {
            // Try latin-1 fallback
            if let text = try? String(contentsOf: url, encoding: .isoLatin1) {
                content = text
                loadedFileURL = url
                hasUnsavedChanges = false
            } else {
                errorMessage = "无法读取文件：\(error.localizedDescription)"
            }
        }
    }

    private func saveFile(_ url: URL) {
        isSaving = true
        let textToSave = content
        Task.detached(priority: .userInitiated) {
            do {
                try textToSave.write(to: url, atomically: true, encoding: .utf8)
                await MainActor.run {
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

// MARK: - Preview

#Preview {
    FileEditorView()
        .environment(WorkspaceState())
        .frame(width: 400, height: 500)
}
