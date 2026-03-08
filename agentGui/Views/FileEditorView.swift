//
//  FileEditorView.swift
//  agentGui
//

import SwiftUI
import AppKit
import PDFKit

// MARK: - File viewer type

private enum FileViewerType { case text, image, pdf }

/// 中间栏：文件编辑器，显示并可编辑当前在文件树中选中的文件
struct FileEditorView: View {

    // MARK: - Environment

    @Environment(WorkspaceState.self) private var workspaceState

    // MARK: - State

    @State private var textContent: String = ""
    @State private var loadedFileURL: URL?
    /// Snapshot of the file content at last load/save; used for dirty detection.
    @State private var fileContent: String = ""
    @State private var errorMessage: String?
    @State private var isSaving = false
    @State private var hasUnsavedChanges: Bool = false
    @State private var viewerType: FileViewerType = .text
    @State private var viewerImage: NSImage? = nil

    // MARK: - Body

    var body: some View {
        Group {
            if let fileURL = workspaceState.selectedFile {
                editorView(for: fileURL)
            } else {
                emptyState
            }
        }
        .onChange(of: textContent) { _, newValue in
            hasUnsavedChanges = loadedFileURL != nil && newValue != fileContent
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
                Image(systemName: viewerType == .pdf ? "doc.richtext" : viewerType == .image ? "photo" : "doc.text")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(url.lastPathComponent + (hasUnsavedChanges ? " •" : ""))
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if viewerType == .text {
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
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.bar)

            Divider()

            fileContentView(for: url)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            if loadedFileURL != url {
                loadFile(url)
            }
        }
    }

    @ViewBuilder
    private func fileContentView(for url: URL) -> some View {
        switch viewerType {
        case .text:
            BlockDocumentEditor(text: $textContent, fileURL: url)
        case .image:
            Group {
                if let img = viewerImage {
                    ScrollView([.horizontal, .vertical]) {
                        Image(nsImage: img)
                            .resizable()
                            .scaledToFit()
                            .padding(16)
                            .frame(maxWidth: .infinity)
                    }
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(Color(NSColor.textBackgroundColor))
        case .pdf:
            PDFKitView(url: url)
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
        if AttachedFile.pathIsImage(url.path) {
            loadedFileURL = url
            viewerType = .image
            hasUnsavedChanges = false
            viewerImage = nil
            Task.detached(priority: .userInitiated) { [url] in
                let img = NSImage(contentsOf: url)
                await MainActor.run { self.viewerImage = img }
            }
            return
        }
        if AttachedFile.pathIsPDF(url.path) {
            loadedFileURL = url
            viewerType = .pdf
            hasUnsavedChanges = false
            viewerImage = nil
            return
        }

        // Text file
        viewerType = .text
        let loadedText: String
        do {
            loadedText = try String(contentsOf: url, encoding: .utf8)
        } catch {
            if let t = try? String(contentsOf: url, encoding: .isoLatin1) {
                loadedText = t
            } else {
                errorMessage = "无法读取文件：\(error.localizedDescription)"
                return
            }
        }

        fileContent = loadedText
        textContent = loadedText
        loadedFileURL = url
        hasUnsavedChanges = false
    }

    private func clearEditor() {
        textContent = ""
        fileContent = ""
        loadedFileURL = nil
        hasUnsavedChanges = false
        viewerType = .text
        viewerImage = nil
    }

    private func saveFile(_ url: URL) {
        isSaving = true
        let textToSave = textContent
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

// MARK: - Preview

#Preview {
    FileEditorView()
        .environment(WorkspaceState())
        .frame(width: 400, height: 500)
}
