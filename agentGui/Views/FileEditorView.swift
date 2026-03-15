//
//  FileEditorView.swift
//  agentGui
//

import SwiftUI
import AppKit
import PDFKit

/// 中间栏：文件编辑器，显示并可编辑当前在文件树中选中的文件
struct FileEditorView: View {

    // MARK: - Environment

    @Environment(WorkspaceState.self) private var workspaceState
    @Environment(ClaudeService.self) private var claudeService
    @Environment(GitPanelViewModel.self) private var gitPanelViewModel
    @Environment(\.modelContext) private var modelContext

    // MARK: - State

    @State private var sessionController = FileEditorSessionController()
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
            sessionController.activate()
            if let selectedFile = workspaceState.selectedFile,
               sessionController.document.fileURL != selectedFile.standardizedFileURL || sessionController.document.phase == .idle {
                Task {
                    await sessionController.open(selectedFile)
                }
            }
        }
        .onDisappear {
            sessionController.deactivate()
        }
        .onChange(of: workspaceState.selectedFile) { _, newURL in
            workspaceState.editorSelection = nil
            Task {
                await sessionController.open(newURL)
            }
            if let url = newURL {
                triggerWorkspaceLSPBootstrap(for: url)
            }
        }
        .alert("错误", isPresented: Binding(
            get: { sessionController.document.errorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    sessionController.clearErrorMessage()
                }
            }
        )) {
            Button("确定") { sessionController.clearErrorMessage() }
        } message: {
            if let msg = sessionController.document.errorMessage { Text(msg) }
        }
    }

    // MARK: - Editor

    private func editorView(for url: URL) -> some View {
        VStack(spacing: 0) {
            // Title bar
            HStack(spacing: 6) {
                Image(systemName: sessionController.document.viewer == .pdf ? "doc.richtext" : sessionController.document.viewer == .image ? "photo" : "doc.text")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(url.lastPathComponent + (sessionController.document.hasUnsavedChanges ? " •" : ""))
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if launchOptions.isUITestMode, sessionController.document.viewer == .text {
                    Text(sessionController.document.hasUnsavedChanges ? "dirty" : "clean")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("fileEditor.dirtyState")
                    Text(sessionController.document.textContent)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: 260, alignment: .trailing)
                        .accessibilityIdentifier("fileEditor.testMirror")
                        .accessibilityLabel(sessionController.document.textContent)
                        .accessibilityValue(sessionController.document.textContent)
                }
                if sessionController.document.viewer == .text {
                    Button {
                        Task {
                            await sessionController.save()
                        }
                    } label: {
                        if sessionController.document.isSaving {
                            ProgressView().scaleEffect(0.6).frame(width: 16, height: 16)
                        } else {
                            Image(systemName: "square.and.arrow.down")
                        }
                    }
                    .buttonStyle(.borderless)
                    .disabled(!sessionController.document.hasUnsavedChanges || sessionController.document.isSaving)
                    .accessibilityIdentifier("fileEditor.saveButton")
                    .help("保存 (⌘S)")
                    .keyboardShortcut("s", modifiers: .command)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.bar)

            Divider()

            if let conflict = sessionController.document.pendingConflict {
                externalConflictBanner(conflict)
                Divider()
            }

            fileContentView(for: url)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            if sessionController.document.fileURL != url.standardizedFileURL || sessionController.document.phase == .idle {
                Task {
                    await sessionController.open(url)
                }
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
                Task {
                    await sessionController.resolveConflict(.keepLocalChanges)
                }
            }
            .buttonStyle(.borderless)
            Button("重新加载") {
                Task {
                    await sessionController.resolveConflict(.reloadFromDisk)
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.08))
    }

    @ViewBuilder
    private func fileContentView(for url: URL) -> some View {
        switch sessionController.document.viewer {
        case .text:
            Group {
                if sessionController.document.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    BlockDocumentEditor(
                        text: Binding(
                            get: { sessionController.document.textContent },
                            set: { newValue in
                                sessionController.updateText(newValue)
                                syncOpenDocumentToLSPIfNeeded(text: newValue)
                            }
                        ),
                        fileURL: url,
                        onSelectionChange: { snapshot in
                            workspaceState.editorSelection = snapshot
                        }
                    )
                }
            }
        case .image:
            Group {
                if let img = sessionController.document.viewerImage {
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

    private func syncOpenDocumentToLSPIfNeeded(text: String) {
        guard sessionController.document.viewer == .text,
              let loadedFileURL = sessionController.document.fileURL,
              text != sessionController.document.persistedText else {
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
