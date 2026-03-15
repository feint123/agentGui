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
    @Environment(ClaudeService.self) private var claudeService
    @Environment(GitPanelViewModel.self) private var gitPanelViewModel
    @Environment(\.modelContext) private var modelContext

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
    @State private var isLoadingFile = false
    @State private var fileLoadTask: Task<Void, Never>?
    @State private var requestTracker = FileEditorRequestTracker()
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
            fileLoadTask?.cancel()
            requestTracker.invalidate()
            openFileRefreshMonitor.watch(nil)
        }
        .onChange(of: textContent) { _, newValue in
            hasUnsavedChanges = loadedFileURL != nil && newValue != fileContent
            syncOpenDocumentToLSPIfNeeded(text: newValue)
        }
        .onChange(of: workspaceState.selectedFile) { _, newURL in
            workspaceState.editorSelection = nil
            externalConflictCoordinator.clear()
            if let url = newURL {
                openFileRefreshMonitor.watch(url)
                loadFile(url)
                triggerWorkspaceLSPBootstrap(for: url)
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
            if loadedFileURL != url || isLoadingFile {
                loadFile(url)
            }
            triggerWorkspaceLSPBootstrap(for: url)
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
            Group {
                if isLoadingFile {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    BlockDocumentEditor(text: $textContent, fileURL: url, onSelectionChange: { snapshot in
                        workspaceState.editorSelection = snapshot
                    })
                }
            }
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
        let standardizedURL = url.standardizedFileURL
        fileLoadTask?.cancel()

        let requestToken = requestTracker.beginRequest(for: standardizedURL)
        prepareForLoading(url: standardizedURL)

        fileLoadTask = Task {
            if AttachedFile.pathIsImage(standardizedURL.path) {
                let image = await Task.detached(priority: .userInitiated) {
                    NSImage(contentsOf: standardizedURL)
                }.value
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard requestTracker.isCurrent(requestToken, for: loadedFileURL) else { return }
                    viewerImage = image
                    isLoadingFile = false
                }
                return
            }

            if AttachedFile.pathIsPDF(standardizedURL.path) {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard requestTracker.isCurrent(requestToken, for: loadedFileURL) else { return }
                    isLoadingFile = false
                }
                return
            }

            do {
                let normalizedText = try await FileEditorLoadedTextState.loadNormalizedText(from: standardizedURL)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard requestTracker.isCurrent(requestToken, for: loadedFileURL) else { return }
                    fileContent = normalizedText
                    textContent = normalizedText
                    hasUnsavedChanges = false
                    isLoadingFile = false
                }
            } catch is CancellationError {
                return
            } catch {
                await MainActor.run {
                    guard requestTracker.isCurrent(requestToken, for: loadedFileURL) else { return }
                    fileContent = ""
                    textContent = ""
                    hasUnsavedChanges = false
                    viewerImage = nil
                    isLoadingFile = false
                    errorMessage = "无法读取文件：\(error.localizedDescription)"
                }
            }
        }
    }

    private func triggerWorkspaceLSPBootstrap(for url: URL) {
        let settings = AppSettings.getOrCreate(in: modelContext)
        let workingDirectory = workspaceState.effectiveWorkingDirectory(globalDefault: settings.workingDirectory)
        Task {
            _ = try? await claudeService.ensureWorkspaceLSPState(
                workingDirectory: workingDirectory,
                selectedFilePath: url.standardizedFileURL.path,
                settings: settings
            )
        }
    }

    private func clearEditor() {
        fileLoadTask?.cancel()
        requestTracker.invalidate()
        externalConflictCoordinator.clear()
        textContent = ""
        fileContent = ""
        loadedFileURL = nil
        hasUnsavedChanges = false
        viewerType = .text
        viewerImage = nil
        isLoadingFile = false
        isSaving = false
    }

    private func saveFile(_ url: URL) {
        let standardizedURL = url.standardizedFileURL
        let saveToken = requestTracker.snapshot(for: standardizedURL)
        isSaving = true
        let textToSave = textContent
        Task.detached(priority: .userInitiated) {
            do {
                try textToSave.write(to: standardizedURL, atomically: true, encoding: .utf8)
                await MainActor.run {
                    guard requestTracker.isCurrent(saveToken, for: loadedFileURL) else { return }
                    self.externalConflictCoordinator.handleSuccessfulSave(for: standardizedURL)
                    self.fileContent = textToSave
                    self.hasUnsavedChanges = false
                    self.isSaving = false
                }
            } catch {
                await MainActor.run {
                    guard requestTracker.isCurrent(saveToken, for: loadedFileURL) else { return }
                    self.errorMessage = "保存失败：\(error.localizedDescription)"
                    self.isSaving = false
                }
            }
        }
    }

    private func prepareForLoading(url: URL) {
        loadedFileURL = url
        textContent = ""
        fileContent = ""
        hasUnsavedChanges = false
        viewerImage = nil
        isSaving = false
        isLoadingFile = true
        errorMessage = nil

        if AttachedFile.pathIsImage(url.path) {
            viewerType = .image
        } else if AttachedFile.pathIsPDF(url.path) {
            viewerType = .pdf
        } else {
            viewerType = .text
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

    private func syncOpenDocumentToLSPIfNeeded(text: String) {
        guard viewerType == .text,
              let loadedFileURL,
              text != fileContent else {
            return
        }

        let settings = AppSettings.getOrCreate(in: modelContext)
        guard settings.enableLSPTools,
              let registry = try? LSPServerRegistry(settings: settings),
              let manager = claudeService.lspServerManager else {
            return
        }

        let workingDirectory = workspaceState.effectiveWorkingDirectory(globalDefault: settings.workingDirectory)
        guard let binding = LSPWorkspaceResolver().resolve(
            filePath: loadedFileURL.standardizedFileURL.path,
            workingDirectory: workingDirectory,
            registry: registry,
            settings: settings
        ) else {
            return
        }

        let languageID = binding.languageID ?? "plaintext"
        manager.syncDocument(
            workspaceRoot: binding.workspaceRoot,
            serverID: binding.serverID,
            uri: loadedFileURL.standardizedFileURL.absoluteString,
            languageID: languageID,
            text: text
        )
    }
}

// MARK: - Preview

#Preview {
    FileEditorView()
        .environment(WorkspaceState())
        .frame(width: 400, height: 500)
}
