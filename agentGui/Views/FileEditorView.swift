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
    @Environment(GitPanelViewModel.self) private var gitPanelViewModel

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
    @State private var openFileRefreshMonitor = OpenFileRefreshMonitor()
    @State private var externalConflictCoordinator = FileEditorExternalConflictCoordinator()
    private let launchOptions = TestLaunchOptions.current

    // MARK: - Body

    var body: some View {
        Group {
            switch FileEditorDisplayMode.resolve(from: workspaceState) {
            case .gitDiff(let title, let diffText):
                GitDiffView(title: title, diffText: diffText)
            case .file(let fileURL):
                editorView(for: fileURL)
            case .empty:
                emptyState
            }
        }
        .onAppear {
            openFileRefreshMonitor.onExternalChange = { changedURL in
                workspaceState.externallyModifiedFile = changedURL
            }
            openFileRefreshMonitor.watch(workspaceState.selectedFile)
        }
        .onDisappear {
            openFileRefreshMonitor.watch(nil)
        }
        .onChange(of: textContent) { _, newValue in
            hasUnsavedChanges = loadedFileURL != nil && newValue != fileContent
        }
        .onChange(of: workspaceState.selectedFile) { _, newURL in
            workspaceState.editorSelection = nil
            externalConflictCoordinator.clear()
            if let url = newURL {
                openFileRefreshMonitor.watch(url)
                loadFile(url)
            } else {
                openFileRefreshMonitor.watch(nil)
                clearEditor()
            }
        }
        .onChange(of: workspaceState.externallyModifiedFile) { _, url in
            guard let url, url == loadedFileURL else { return }
            workspaceState.externallyModifiedFile = nil
            applyExternalConflictOutcome(
                externalConflictCoordinator.handleExternalChange(
                    changedURL: url,
                    loadedURL: loadedFileURL,
                    hasUnsavedChanges: hasUnsavedChanges
                )
            )
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
                if launchOptions.isUITestMode, viewerType == .text {
                    Text(hasUnsavedChanges ? "dirty" : "clean")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("fileEditor.dirtyState")
                    Text(textContent)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: 260, alignment: .trailing)
                        .accessibilityIdentifier("fileEditor.testMirror")
                        .accessibilityLabel(textContent)
                        .accessibilityValue(textContent)
                }
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
                    .accessibilityIdentifier("fileEditor.saveButton")
                    .help("保存 (⌘S)")
                    .keyboardShortcut("s", modifiers: .command)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.bar)

            Divider()

            if let conflict = externalConflictCoordinator.pendingConflict {
                externalConflictBanner(conflict)
                Divider()
            }

            fileContentView(for: url)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            openFileRefreshMonitor.watch(url)
            externalConflictCoordinator.clear()
            if loadedFileURL != url {
                loadFile(url)
            }
        }
    }

    private func externalConflictBanner(_ conflict: FileEditorExternalConflict) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("磁盘版本已变化，本地也有未保存修改。")
                    .font(.caption.weight(.semibold))
                Text(conflict.url.lastPathComponent)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Button("保留当前编辑") {
                applyExternalConflictOutcome(externalConflictCoordinator.resolve(.keepLocalChanges))
            }
            .buttonStyle(.borderless)
            Button("重新加载") {
                applyExternalConflictOutcome(externalConflictCoordinator.resolve(.reloadFromDisk))
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.08))
    }

    @ViewBuilder
    private func fileContentView(for url: URL) -> some View {
        switch viewerType {
        case .text:
            BlockDocumentEditor(text: $textContent, fileURL: url, onSelectionChange: { snapshot in
                workspaceState.editorSelection = snapshot
            })
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
            Text(gitPanelViewModel.snapshot == nil ? "从左侧文件树中单击文件来打开" : "从左侧文件树或 Git 面板中选择文件")
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

        let normalizedText = FileEditorLoadedTextState.normalizedTextForInitialLoad(loadedText, fileURL: url)

        fileContent = normalizedText
        textContent = normalizedText
        loadedFileURL = url
        hasUnsavedChanges = false
    }

    private func clearEditor() {
        externalConflictCoordinator.clear()
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
                    self.externalConflictCoordinator.handleSuccessfulSave(for: url)
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

    private func applyExternalConflictOutcome(_ outcome: FileEditorExternalConflictOutcome) {
        switch outcome {
        case .none, .presentConflict:
            break
        case .reload(let url):
            loadFile(url)
        }
    }
}

// MARK: - Preview

#Preview {
    FileEditorView()
        .environment(WorkspaceState())
        .frame(width: 400, height: 500)
}
