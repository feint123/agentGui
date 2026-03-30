//
//  FileEditorView.swift
//  agentGui
//

import SwiftUI
import AppKit
import PDFKit

/// 文件编辑器，显示并可编辑指定文件
struct FileEditorView: View {

    let fileURL: URL

    // MARK: - Environment

    @Environment(WorkspaceState.self) private var workspaceState
    @Environment(ClaudeService.self) private var claudeService
    @Environment(\.modelContext) private var modelContext

    // MARK: - State

    @State private var sessionController = FileEditorSessionController()
    @State private var lspCoordinator: CodeEditorLSPCoordinator?
    @State private var lspDocumentBinding: CodeEditorLSPDocumentBinding?
    @State private var lspDocumentVersion = 0
    private let launchOptions = TestLaunchOptions.current

    // MARK: - Body

    var body: some View {
        let _ = claudeService.lspPresentationRevision

        editorView(for: fileURL)
        .onAppear {
            sessionController.activate()
            if sessionController.document.fileURL != fileURL.standardizedFileURL || sessionController.document.phase == .idle {
                Task {
                    await sessionController.open(fileURL)
                }
            }
            syncLSPCoordinator(for: fileURL)
        }
        .onDisappear {
            deactivateLSPCoordinator()
            sessionController.deactivate()
        }
        .onChange(of: fileURL) { _, newURL in
            deactivateLSPCoordinator()
            lspDocumentVersion = 0
            workspaceState.editorSelection = nil
            Task {
                await sessionController.open(newURL)
            }
            triggerWorkspaceLSPBootstrap(for: newURL)
        }
        .onChange(of: sessionController.document.phase) { _, _ in
            syncLSPCoordinator(for: fileURL)
        }
        .onChange(of: sessionController.document.viewer) { _, _ in
            syncLSPCoordinator(for: fileURL)
        }
        .onChange(of: sessionController.document.fileURL) { _, _ in
            syncLSPCoordinator(for: fileURL)
        }
        .onChange(of: claudeService.lspPresentationRevision) { _, _ in
            syncLSPCoordinator(for: fileURL)
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
            FilePathBreadcrumbBar(
                iconSystemName: fileViewerIconName,
                items: breadcrumbItems(for: url)
            ) {
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

    private var fileViewerIconName: String {
        switch sessionController.document.viewer {
        case .pdf:
            return "doc.richtext"
        case .image:
            return "photo"
        case .text:
            return "doc.text"
        }
    }

    private func breadcrumbItems(for url: URL) -> [BreadcrumbNavigationItem] {
        let settings = AppSettings.getOrCreate(in: modelContext)
        let rootURL = workspaceState.effectiveWorkingDirectoryURL(globalDefault: settings.workingDirectory)
        var items = FilePathBreadcrumbs.makeItems(for: url, relativeTo: rootURL)

        if let lastIndex = items.indices.last,
           sessionController.document.hasUnsavedChanges {
            let item = items[lastIndex]
            items[lastIndex] = BreadcrumbNavigationItem(
                title: item.title + " •",
                url: item.url,
                isCurrent: item.isCurrent
            )
        }

        return items
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
                    CodeEditorView(
                        text: Binding(
                            get: { sessionController.document.textContent },
                            set: { newValue in
                                sessionController.updateText(newValue)
                            }
                        ),
                        persistedText: sessionController.document.persistedText,
                        fileURL: url,
                        diagnostics: currentFileDiagnosticsSnapshot(for: url),
                        lspStatus: currentLSPStatus(for: url),
                        onSelectionChange: { snapshot in
                            workspaceState.editorSelection = snapshot
                        },
                        onTextChange: { newValue, change in
                            lspDocumentVersion = change.version
                            lspCoordinator?.handleTextChange(text: newValue, change: change)
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
            await MainActor.run {
                syncLSPCoordinator(for: url)
            }
        }
    }

    private func syncLSPCoordinator(for url: URL) {
        let targetURL = url.standardizedFileURL

        guard let loadedFileURL = sessionController.document.fileURL?.standardizedFileURL,
              loadedFileURL == targetURL,
              sessionController.document.viewer == .text,
              sessionController.document.phase != .loading else {
            deactivateLSPCoordinator()
            return
        }

        guard let binding = resolveLSPDocumentBinding(for: targetURL),
              let manager = claudeService.lspServerManager else {
            deactivateLSPCoordinator()
            return
        }

        if lspDocumentBinding != binding || lspCoordinator == nil {
            deactivateLSPCoordinator()
            lspDocumentBinding = binding
            lspCoordinator = CodeEditorLSPCoordinator(manager: manager, binding: binding)
        }

        lspCoordinator?.activate(
            initialText: sessionController.document.textContent,
            version: lspDocumentVersion
        )
    }

    private func deactivateLSPCoordinator() {
        lspCoordinator?.deactivate()
        lspCoordinator = nil
        lspDocumentBinding = nil
    }

    private func resolveLSPDocumentBinding(for url: URL) -> CodeEditorLSPDocumentBinding? {
        let settings = AppSettings.getOrCreate(in: modelContext)
        guard settings.enableLSPTools,
              let registry = try? LSPServerRegistry(settings: settings) else {
            return nil
        }

        let workingDirectory = workspaceState.effectiveWorkingDirectory(globalDefault: settings.workingDirectory)
        guard let binding = LSPWorkspaceResolver().resolve(
            filePath: url.path,
            workingDirectory: workingDirectory,
            registry: registry,
            settings: settings
        ) else {
            return nil
        }

        return CodeEditorLSPDocumentBinding(
            workspaceRoot: binding.workspaceRoot,
            serverID: binding.serverID,
            uri: url.absoluteString,
            languageID: binding.languageID ?? "plaintext"
        )
    }

    private func currentLSPStatus(for url: URL) -> WorkspacePanelLSPStatusPresentation? {
        let settings = AppSettings.getOrCreate(in: modelContext)
        let workingDirectory = workspaceState.effectiveWorkingDirectory(globalDefault: settings.workingDirectory)
        guard !workingDirectory.isEmpty else {
            return nil
        }

        return claudeService.makeWorkspacePanelLSPStatus(
            workingDirectory: workingDirectory,
            selectedFilePath: url.standardizedFileURL.path,
            settings: settings
        )
    }

    private func currentFileDiagnosticsSnapshot(for url: URL) -> LSPDiagnosticsSnapshot? {
        let settings = AppSettings.getOrCreate(in: modelContext)
        let workingDirectory = workspaceState.effectiveWorkingDirectory(globalDefault: settings.workingDirectory)
        guard !workingDirectory.isEmpty else {
            return nil
        }

        let snapshot = claudeService.lspServerManager?.diagnosticsStore.snapshot(
            for: workingDirectory,
            uri: url.standardizedFileURL.absoluteString
        )

        guard lspCoordinator?.acceptsDiagnostics(snapshot) ?? true else {
            return nil
        }

        return snapshot
    }
}

// MARK: - Preview

#Preview {
    FileEditorView(fileURL: URL(fileURLWithPath: "/tmp/Preview.swift"))
        .environment(WorkspaceState())
        .frame(width: 400, height: 500)
}
