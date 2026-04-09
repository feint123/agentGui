//
//  FileEditorView.swift
//  agentGui
//

import SwiftUI
import AppKit
import PDFKit

struct FileEditorCodeEditorRuntimeOptions: Equatable {
    let isCompletionEnabled: Bool
    let isInlayHintsEnabled: Bool

    static func from(hasLSPCoordinator: Bool) -> FileEditorCodeEditorRuntimeOptions {
        FileEditorCodeEditorRuntimeOptions(
            isCompletionEnabled: hasLSPCoordinator,
            isInlayHintsEnabled: hasLSPCoordinator
        )
    }
}

/// 文件编辑器，显示并可编辑指定文件
struct FileEditorView: View {

    let fileURL: URL

    // MARK: - Environment

    @Environment(WorkspaceState.self) private var workspaceState
    @Environment(ClaudeService.self) private var claudeService
    @Environment(\.modelContext) private var modelContext
    @Environment(ChangeReviewProjectionStore.self) private var changeReviewStore

    // MARK: - State

    @State private var sessionController = FileEditorSessionController()
    @State private var lspCoordinator: CodeEditorLSPCoordinator?
    @State private var lspDocumentBinding: CodeEditorLSPDocumentBinding?
    @State private var lspDocumentVersion = 0
    @State private var activeRevealRequest: CodeEditorRevealRequest?
    @State private var hoverPresentation: CodeEditorHoverPresentation?
    @State private var referencesPresentation: CodeEditorReferencePresentation?
    @State private var documentSymbolItems: [CodeEditorDocumentSymbolItem] = []
    @State private var rawDocumentSymbols: [LSPDocumentSymbol] = []
    @State private var currentSymbolPath: [CodeEditorSymbolPathNode] = []
    @State private var isSymbolOutlinePresented: Bool = false
    @State private var gitDiffByLine: [Int: CodeEditorGitDiffKind] = [:]
    @State private var agentChangeDiffByLine: [Int: CodeEditorGitDiffKind] = [:]
    private let gitDiffService = GitLineDiffService()
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
            consumePendingRevealRequestIfNeeded(for: fileURL)
            syncLSPCoordinator(for: fileURL)
            refreshGitDiff(for: fileURL)
            refreshAgentDiff(for: fileURL)
        }
        .onDisappear {
            lspCoordinator?.cancelHover()
            deactivateLSPCoordinator()
            sessionController.deactivate()
        }
        .onChange(of: fileURL) { _, newURL in
            lspCoordinator?.cancelHover()
            deactivateLSPCoordinator()
            lspDocumentVersion = 0
            activeRevealRequest = nil
            hoverPresentation = nil
            referencesPresentation = nil
            documentSymbolItems = []
            rawDocumentSymbols = []
            currentSymbolPath = []
            workspaceState.editorSelection = nil
            Task {
                await sessionController.open(newURL)
            }
            consumePendingRevealRequestIfNeeded(for: newURL)
            triggerWorkspaceLSPBootstrap(for: newURL)
            gitDiffByLine = [:]
            agentChangeDiffByLine = [:]
            refreshGitDiff(for: newURL)
            refreshAgentDiff(for: newURL)
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
        .onChange(of: sessionController.document.hasUnsavedChanges) { _, isDirty in
            // 文件从修改状态变为已保存（dirty → clean）时刷新 diff
            if !isDirty {
                refreshGitDiff(for: fileURL)
            }
        }
        .onChange(of: changeReviewStore.snapshotsByProposalID) { _, _ in
            refreshAgentDiff(for: fileURL)
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
        .sheet(item: $referencesPresentation) { presentation in
            referencesSheet(presentation)
        }
        .overlay(alignment: .top) {
            if isSymbolOutlinePresented {
                CodeEditorSymbolOutlineView(
                    symbols: documentSymbolItems,
                    onNavigate: { request in
                        isSymbolOutlinePresented = false
                        executeNavigationAction(
                            CodeEditorViewModel.navigationAction(
                                currentFileURL: fileURL,
                                revealRequest: request
                            )
                        )
                    },
                    onDismiss: {
                        isSymbolOutlinePresented = false
                    }
                )
                .padding(.top, 40)
            }
        }
        .background {
            Button("") {
                if sessionController.document.viewer == .text {
                    isSymbolOutlinePresented.toggle()
                    if isSymbolOutlinePresented && documentSymbolItems.isEmpty {
                        refreshDocumentSymbols(for: fileURL)
                    }
                }
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])
            .hidden()
            .accessibilityHidden(true)
        }
    }

    // MARK: - Editor

    private func editorView(for url: URL) -> some View {
        VStack(spacing: 0) {
            UnifiedEditorBreadcrumbBar(
                iconSystemName: fileViewerIconName,
                fileItems: breadcrumbItems(for: url),
                symbolPath: sessionController.document.viewer == .text ? currentSymbolPath : [],
                onNavigateSymbol: { request in
                    executeNavigationAction(
                        CodeEditorViewModel.navigationAction(
                            currentFileURL: url,
                            revealRequest: request
                        )
                    )
                }
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
                    Menu {
                        Button("刷新符号") {
                            refreshDocumentSymbols(for: url)
                        }

                        if documentSymbolItems.isEmpty {
                            Text("暂无符号")
                        } else {
                            Divider()
                            ForEach(documentSymbolItems) { item in
                                Button(item.title) {
                                    executeNavigationAction(
                                        CodeEditorViewModel.navigationAction(
                                            currentFileURL: url,
                                            revealRequest: item.revealRequest
                                        )
                                    )
                                }
                                .help(item.subtitle ?? "")
                            }
                        }
                    } label: {
                        Image(systemName: "list.bullet.indent")
                    }
                    .menuStyle(.borderlessButton)
                    .help("当前文件符号")

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
                    let runtimeOptions = FileEditorCodeEditorRuntimeOptions.from(
                        hasLSPCoordinator: lspCoordinator != nil
                    )
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
                        revealRequest: activeRevealRequest,
                        hoverPresentation: hoverPresentation,
                        onSelectionChange: { snapshot in
                            scheduleViewStateMutation {
                                workspaceState.editorSelection = snapshot
                            }
                        },
                        onSemanticIntent: { intent in
                            handleSemanticIntent(intent, for: url)
                        },
                        onTextChange: { newValue, change in
                            scheduleViewStateMutation {
                                lspDocumentVersion = change.version
                                documentSymbolItems = []
                                rawDocumentSymbols = []
                            }
                            lspCoordinator?.handleTextChange(text: newValue, change: change)
                        },
                        gitDiffByLine: gitDiffByLine,
                        agentChangeDiffByLine: agentChangeDiffByLine,
                        isBracketPairColorizationEnabled: AppSettings.getOrCreate(in: modelContext).isBracketPairColorizationEnabled,
                        documentSymbols: rawDocumentSymbols,
                        onSymbolPathChange: { path in
                            currentSymbolPath = path
                        },
                        lspCoordinator: lspCoordinator,
                        isCompletionEnabled: runtimeOptions.isCompletionEnabled,
                        isInlayHintsEnabled: runtimeOptions.isInlayHintsEnabled,
                        isGhostTextEnabled: AppSettings.getOrCreate(in: modelContext).enableGhostText,
                        ghostTextClient: claudeService.service.map { AnthropicGhostTextClient(service: $0) },
                        ghostTextModelId: AppSettings.getOrCreate(in: modelContext).selectedModel,
                        onGutterLaneHit: { hitResult in
                            handleGutterLaneHit(hitResult, for: url)
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

    // MARK: - Git Diff

    private func refreshGitDiff(for fileURL: URL) {
        guard let rootURL = resolveWorkspaceRoot() else { return }
        Task { @MainActor in
            let result = await gitDiffService.fetchLineDiff(
                fileURL: fileURL.standardizedFileURL,
                workspaceRoot: rootURL
            )
            gitDiffByLine = result
        }
    }

    private func resolveWorkspaceRoot() -> URL? {
        let settings = AppSettings.getOrCreate(in: modelContext)
        return workspaceState.effectiveWorkingDirectoryURL(globalDefault: settings.workingDirectory)
    }

    // MARK: - Agent Change Diff（F24）

    private func refreshAgentDiff(for fileURL: URL) {
        let standardizedURL = fileURL.standardizedFileURL
        // 遍历 store 中所有 pending 的 fileChanges，找到匹配当前文件的条目
        let matchingDiff = changeReviewStore.snapshotsByProposalID.values
            .flatMap { $0.fileChanges }
            .filter { $0.state.isPendingReview }
            .first { fc in
                URL(fileURLWithPath: fc.absolutePath).standardizedFileURL == standardizedURL
            }
            .map { UnifiedDiffParser.parse($0.unifiedDiff) }

        agentChangeDiffByLine = matchingDiff ?? [:]
    }

    // MARK: - Gutter Lane Hit Handling（F24）

    private func handleGutterLaneHit(
        _ hitResult: CodeEditorGutterHitResult,
        for fileURL: URL
    ) {
        guard hitResult.laneID == "changeReviewAction" else { return }
        let encodedLine = hitResult.lineNumber
        let isAccept = encodedLine > 0
        _ = abs(encodedLine)   // 行号（当前按文件维度操作，保留供后续 hunk 级精细化）

        guard let (proposalID, relativePath) = findPendingChange(
            in: changeReviewStore,
            fileURL: fileURL
        ) else { return }

        let applyEngine = ApplyEngine(modelContext: modelContext,
                                      projectionStore: changeReviewStore)
        let revertService = DraftRevertService(modelContext: modelContext,
                                               projectionStore: changeReviewStore)
        Task { @MainActor in
            do {
                if isAccept {
                    try await applyEngine.apply(proposalID: proposalID, approvedPaths: [relativePath])
                } else {
                    try await revertService.revertFiles(proposalID: proposalID, relativePaths: [relativePath])
                }
                // 操作成功后刷新 git diff（文件内容已修改）
                refreshGitDiff(for: fileURL)
            } catch {
                // 错误静默处理（后续可接入 sessionController.document.errorMessage）
            }
        }
    }

    private func findPendingChange(
        in store: ChangeReviewProjectionStore,
        fileURL: URL
    ) -> (proposalID: UUID, relativePath: String)? {
        let standardized = fileURL.standardizedFileURL
        for snapshot in store.snapshotsByProposalID.values {
            for fc in snapshot.fileChanges where fc.state.isPendingReview {
                if URL(fileURLWithPath: fc.absolutePath).standardizedFileURL == standardized {
                    return (snapshot.proposal.id, fc.relativePath)
                }
            }
        }
        return nil
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

        if documentSymbolItems.isEmpty {
            refreshDocumentSymbols(for: url)
        }
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

    private func handleSemanticIntent(_ intent: CodeEditorSemanticIntent, for currentFileURL: URL) {
        switch intent {
        case let .requestDefinition(position):
            guard let requestCoordinator = lspCoordinator else {
                return
            }

            Task {
                guard let revealRequest = await requestCoordinator.requestDefinition(at: position) else {
                    return
                }

                await MainActor.run {
                    guard semanticResultIsCurrent(
                        for: requestCoordinator,
                        fileURL: currentFileURL
                    ) else {
                        return
                    }

                    executeNavigationAction(
                        CodeEditorViewModel.navigationAction(
                            currentFileURL: currentFileURL,
                            revealRequest: revealRequest
                        )
                    )
                }
            }
        case let .requestReferences(position):
            guard let requestCoordinator = lspCoordinator else {
                return
            }

            Task {
                let presentation = await requestCoordinator.requestReferences(at: position)
                await MainActor.run {
                    guard semanticResultIsCurrent(
                        for: requestCoordinator,
                        fileURL: currentFileURL
                    ) else {
                        return
                    }

                    referencesPresentation = presentation
                }
            }
        case let .requestHover(position):
            lspCoordinator?.scheduleHover(at: position, debounceNanoseconds: 250_000_000) { presentation in
                self.scheduleViewStateMutation {
                    self.hoverPresentation = presentation
                }
            }
        case .cancelHover:
            lspCoordinator?.cancelHover()
            scheduleViewStateMutation {
                hoverPresentation = nil
            }
        }
    }

    private func executeNavigationAction(_ action: CodeEditorSemanticNavigationAction) {
        switch action {
        case let .revealInCurrentFile(revealRequest):
            scheduleViewStateMutation {
                activeRevealRequest = revealRequest
            }
        case let .openFileAndReveal(targetURL, revealRequest):
            scheduleViewStateMutation {
                workspaceState.pendingCodeEditorRevealRequest = revealRequest
                workspaceState.showFileDetail(targetURL)
            }
        case .unsupported:
            break
        }
    }

    private func consumePendingRevealRequestIfNeeded(for url: URL) {
        guard let revealRequest = workspaceState.consumePendingCodeEditorRevealRequest(for: url) else {
            return
        }

        scheduleViewStateMutation {
            activeRevealRequest = revealRequest
        }
    }

    private func refreshDocumentSymbols(for url: URL) {
        let documentVersion = lspDocumentVersion
        guard let requestCoordinator = lspCoordinator else {
            documentSymbolItems = []
            rawDocumentSymbols = []
            return
        }

        Task {
            let symbols = await requestCoordinator.requestDocumentSymbols(documentVersion: documentVersion)
            let items = CodeEditorViewModel.flattenedDocumentSymbols(symbols, fileURL: url)
            await MainActor.run {
                guard semanticResultIsCurrent(for: requestCoordinator, fileURL: url) else {
                    return
                }

                scheduleViewStateMutation {
                    documentSymbolItems = items
                    rawDocumentSymbols = symbols
                }
            }
        }
    }

    private func scheduleViewStateMutation(_ action: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            action()
        }
    }

    private func semanticResultIsCurrent(
        for coordinator: CodeEditorLSPCoordinator,
        fileURL: URL
    ) -> Bool {
        guard lspCoordinator === coordinator else {
            return false
        }

        return sessionController.document.fileURL?.standardizedFileURL == fileURL.standardizedFileURL
    }

    private func referencesSheet(_ presentation: CodeEditorReferencePresentation) -> some View {
        NavigationStack {
            List(presentation.items) { item in
                Button {
                    referencesPresentation = nil
                    let revealRequest = CodeEditorRevealRequest(
                        fileURL: item.fileURL,
                        line: item.line,
                        column: item.column,
                        reason: .reference
                    )
                    executeNavigationAction(
                        CodeEditorViewModel.navigationAction(
                            currentFileURL: fileURL,
                            revealRequest: revealRequest
                        )
                    )
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                        Text(item.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("引用")
        }
        .frame(minWidth: 360, minHeight: 240)
    }
}

// MARK: - Preview

#Preview {
    FileEditorView(fileURL: URL(fileURLWithPath: "/tmp/Preview.swift"))
        .environment(WorkspaceState())
        .frame(width: 400, height: 500)
}
