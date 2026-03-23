//
//  ChatView+InputArea.swift
//  agentGui
//

import SwiftUI
import UniformTypeIdentifiers
import AppKit

extension ChatView {

    private func debugSlashLog(_ message: String) {
        print("[Slash][\(resolvedExecutionProviderID.rawValue)][session=\(session.sessionId)] \(message)")
    }

    private var testLaunchOptions: TestLaunchOptions {
        TestLaunchOptions.current
    }

    private var composerExecutionPresentation: ChatComposerExecutionPresentation {
        ChatComposerExecutionPresentation.resolve(
            usesExecutionProjectionUI: usesExecutionProjectionUI,
            projection: sessionExecutionProjection,
            legacyIsStreaming: claudeService.isStreaming,
            canSend: canSend
        )
    }

    private var changeReviewProjection: SessionChangeReviewProjection {
        changeReviewProjectionStore.projection(forSessionID: session.sessionId)
    }

    private var proposalDockPresentation: ProposalDockPresentation {
        ProposalDockPresenter().build(
            from: changeReviewProjection,
            snapshotsByProposalID: changeReviewProjectionStore.snapshotsByProposalID
        )
    }

    private var displayedSlashCandidates: [ChatSlashCommandItem] {
        slashCandidates
    }

    private var displayedMentionCandidates: [URL] {
        Array(mentionCandidates.prefix(8))
    }

    // MARK: - Input Area

    var inputArea: some View {
        VStack(spacing: 0) {
            switch assistSurface {
            case .slash:
                slashPopupCard
            case .mention:
                mentionPopupCard
            case .todo:
                todoPopupCard
            case .none:
                EmptyView()
            }

            ProposalDockView(
                presentation: proposalDockPresentation,
                selectedProposalID: workspaceState.selectedChangeProposalID,
                selectedFilePath: workspaceState.selectedChangeProposalFilePath,
                onOpenProposal: { item in
                    openChangeReviewFromComposer(proposalID: item.proposalID, filePath: item.filePath)
                },
                onApplyProposal: { item in
                    applyProposalFromDock(item: item)
                },
                onDiscardProposal: { item in
                    discardProposalFromDock(item: item)
                },
                onApplyAll: {
                    applyAllProposalsFromDock()
                },
                onDiscardAll: {
                    discardAllProposalsFromDock()
                }
            )

            VStack(spacing: 8) {
                if (showFileContext && workspaceState.selectedFile != nil) ||
                    (showSelectionContext && workspaceState.editorSelectedText != nil) {
                    contextChipsRow
                }
                if !attachedFiles.isEmpty {
                    fileChipsRow
                }
                if !activeInputDirectives.isEmpty {
                    inputDirectiveChipsRow
                }

                HStack(spacing: 8) {
                    ExecutionOptionPicker(
                        title: "",
                        options: ConversationExecutionProviderID.optionItems(
                            copilotAvailabilityStatus: copilotComposerAvailabilityStatus,
                            openCodeAvailabilityStatus: openCodeComposerAvailabilityStatus
                        ),
                        selection: executionProviderSelectionRawValueBinding,
                        accessibilityIdentifier: "chat.executionProviderPicker"
                    )
                    .disabled(sessionInteractionPolicy.canSend == false)

                    composerExecutionPreferencesControls
                        .disabled(sessionInteractionPolicy.canSend == false)

                    if resolvedExecutionProviderID == .githubCopilotCLI,
                       copilotComposerAvailabilityStatus.kind != .available {
                        Text(copilotComposerAvailabilityStatus.summaryText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    } else if resolvedExecutionProviderID == .openCodeCLI,
                              openCodeComposerAvailabilityStatus.kind != .available {
                        Text(openCodeComposerAvailabilityStatus.summaryText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }

                    Spacer(minLength: 0)

                    if composerExecutionPresentation.showsRunningBadge {
                        Text("运行中")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let queueBadgeText = composerExecutionPresentation.queueBadgeText {
                        Text(queueBadgeText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("chat.queueBadge")
                    }

                }

                HStack(alignment: .bottom, spacing: 10) {
                    MentionAwareEditor(
                        text: $inputText,
                        height: $composerHeight,
                        isDisabled: composerExecutionPresentation.isComposerDisabled,
                        onTextChange: { updateComposerAssistState($0) },
                        onMoveSelection: { handleComposerSelectionMove(delta: $0) },
                        onCommitSelection: { commitComposerSelection() },
                        onCancelAssist: { cancelComposerAssist() },
                        onFileDrop: { urls in
                            for url in urls {
                                guard !attachedFiles.contains(where: { $0.url == url }) else { continue }
                                attachedFiles.append(AttachedFile(name: url.lastPathComponent, url: url))
                            }
                        }
                    )
                    .frame(height: composerHeight)
                    .padding(.horizontal, 4)
                    .accessibilityIdentifier("chat.inputField")

                    sendButton
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .glassEffect(composerShellGlass,
                         in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(.horizontal, 16)
        .padding(.bottom, 6)
        .padding(.top, 8)
        .accessibilityIdentifier("chat.inputArea")
        .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted) { providers in
            handleFileDrop(providers: providers)
        }

        HStack {
            Spacer()
            ContextUsageRingView(service: claudeService)
            Spacer()
        }
        .padding(.bottom, 10)
    }
    .background(.bar)
    .onAppear {
        applyUITestInitialComposerTextIfNeeded()
    }
    .task(id: copilotComposerAvailabilityRefreshToken) {
        await refreshCopilotComposerAvailabilityStatus()
        await refreshOpenCodeComposerAvailabilityStatus()
    }
}

    private var composerShellGlass: Glass {
        if isDropTargeted {
            return .regular.interactive().tint(Color.accentColor.opacity(0.3))
        }
        if sessionInteractionPolicy.canSend == false {
            return .regular.tint(Color.secondary.opacity(0.12))
        }
        return .regular
    }

    private func applyUITestInitialComposerTextIfNeeded() {
        guard testLaunchOptions.isUITestMode,
              !didApplyUITestInitialComposerText,
              let initialComposerText = testLaunchOptions.initialComposerText else {
            return
        }

        didApplyUITestInitialComposerText = true
        inputText = initialComposerText
        updateComposerAssistState(initialComposerText)
    }

    private var currentTodoItems: [TodoItem] {
        let store = SessionTaskStateStore(modelContext: modelContext)
        let persistedItems = store.todoItems(for: session.sessionId)
        if !persistedItems.isEmpty {
            return persistedItems
        }
        return claudeService.sessionTodoLists[session.sessionId] ?? []
    }

    private var todoCardPresentation: ChatComposerTodoCardPresentation {
        ChatComposerTodoCardPresentation.build(items: currentTodoItems, maxVisibleItems: 4)
    }

    private var assistSurface: ChatComposerAssistSurface {
        ChatComposerAssistSurface.resolve(
            slashQuery: slashQuery,
            hasMentionCandidates: !mentionCandidates.isEmpty,
            mentionQuery: mentionQuery,
            todoPresentation: todoCardPresentation
        )
    }

    @ViewBuilder
    private var composerExecutionPreferencesControls: some View {
        switch resolvedExecutionProviderID {
        case .builtInAgent:
            ExecutionOptionPicker(
                title: "",
                options: AppSettings.availableModelOptions(inheritingTitle: "跟随全局设置"),
                selection: builtInComposerModelSelectionBinding,
                accessibilityIdentifier: "chat.builtInModelPicker"
            )

            ExecutionOptionPicker(
                title: "",
                options: GitHubCopilotCLIApprovalModeOption.allCases.map {
                    ExecutionOptionItem(id: $0.rawValue, title: $0.title)
                },
                selection: builtInComposerApprovalModeSelectionBinding,
                accessibilityIdentifier: "chat.builtInApprovalModePicker"
            )
        case .githubCopilotCLI:
            ExecutionOptionPicker(
                title: "",
                options: ACPCLIConfiguration.copilotModelOptions(
                    inheritingTitle: "跟随设置默认",
                    including: copilotComposerModelSelectionBinding.wrappedValue
                ),
                selection: copilotComposerModelSelectionBinding,
                accessibilityIdentifier: "chat.copilotModelPicker"
            )

            ExecutionOptionPicker(
                title: "",
                options: GitHubCopilotCLIApprovalModeOption.allCases.map {
                    ExecutionOptionItem(id: $0.rawValue, title: $0.title)
                },
                selection: copilotComposerApprovalModeSelectionBinding,
                accessibilityIdentifier: "chat.copilotApprovalModePicker"
            )
        case .openCodeCLI:
            ExecutionOptionPicker(
                title: "",
                options: AppSettings.availableModelOptions(inheritingTitle: "跟随设置默认"),
                selection: openCodeComposerModelSelectionBinding,
                accessibilityIdentifier: "chat.openCodeModelPicker"
            )

            ExecutionOptionPicker(
                title: "",
                options: GitHubCopilotCLIApprovalModeOption.allCases.map {
                    ExecutionOptionItem(id: $0.rawValue, title: $0.title)
                },
                selection: openCodeComposerApprovalModeSelectionBinding,
                accessibilityIdentifier: "chat.openCodeApprovalModePicker"
            )
        }
    }

    // MARK: - Context Chips

    var contextChipsRow: some View {
        HStack(spacing: 6) {
            if let fileURL = workspaceState.selectedFile,
               showFileContext || (showSelectionContext && workspaceState.editorSelectedText?.isEmpty == false) {
                contextChip(
                    systemImage: "text.cursor",
                    label: combinedFileContextLabel,
                    tint: .orange
                ) {
                    showFileContext = false
                    showSelectionContext = false
                }
            } else if showFileContext, let fileURL = workspaceState.selectedFile {
                contextChip(
                    systemImage: "doc.text",
                    label: WorkspaceFileContextFormatter.displayLabel(for: fileURL),
                    tint: .accentColor
                ) { showFileContext = false }
            }
            Spacer(minLength: 0)
        }
    }

    private var combinedFileContextLabel: String {
        if let fileURL = workspaceState.selectedFile {
            return WorkspaceFileContextFormatter.displayLabel(
                for: fileURL,
                lineRange: workspaceState.editorSelectedLineRange
            )
        }
        return workspaceState.editorSelectedLineRange?.displayText ?? "已选文本"
    }

    private func openChangeReviewFromComposer(proposalID: UUID? = nil, filePath: String? = nil) {
        guard let proposalID = proposalID ?? changeReviewProjection.proposalIDs.first else { return }
        let initialPath = filePath ?? changeReviewProjectionStore
            .snapshot(for: proposalID)?
            .fileChanges
            .first(where: { $0.state.isPendingReview })?
            .relativePath
        workspaceState.selectChangeProposal(proposalID, filePath: initialPath)
    }

    private func applyProposalFromDock(item: ProposalDockItemPresentation) {
        guard !item.filePath.isEmpty else { return }

        Task {
            do {
                try await ApplyEngine(
                    modelContext: modelContext,
                    projectionStore: changeReviewProjectionStore
                ).apply(proposalID: item.proposalID, approvedPaths: [item.filePath])
                reconcileProposalSelectionAfterDockAction(proposalID: item.proposalID)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func discardProposalFromDock(item: ProposalDockItemPresentation) {
        guard !item.filePath.isEmpty else { return }

        Task {
            do {
                try await DraftRevertService(
                    modelContext: modelContext,
                    projectionStore: changeReviewProjectionStore
                ).revertFiles(
                    proposalID: item.proposalID,
                    relativePaths: [item.filePath]
                )
                reconcileProposalSelectionAfterDockAction(proposalID: item.proposalID)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func reconcileProposalSelectionAfterDockAction(proposalID: UUID) {
        guard workspaceState.selectedChangeProposalID == proposalID else { return }

        guard let snapshot = changeReviewProjectionStore.snapshot(for: proposalID),
              snapshot.proposal.state.isPendingReview else {
            workspaceState.clearChangeProposalSelection()
            return
        }

        let nextPath = ChangeProposalReviewSelectionResolver.resolve(
            in: snapshot,
            selectedFilePath: workspaceState.selectedChangeProposalFilePath
        )?.relativePath
        workspaceState.selectChangeProposal(proposalID, filePath: nextPath)
    }

    private func applyAllProposalsFromDock() {
        performProposalDockBulkAction(.apply)
    }

    private func discardAllProposalsFromDock() {
        performProposalDockBulkAction(.discard)
    }

    private func performProposalDockBulkAction(_ action: ProposalDockBulkAction) {
        let proposalIDs = proposalDockPresentation.actionableProposalIDs
        guard !proposalIDs.isEmpty else { return }

        Task {
            do {
                switch action {
                case .apply:
                    let applyEngine = ApplyEngine(
                        modelContext: modelContext,
                        projectionStore: changeReviewProjectionStore
                    )
                    for proposalID in proposalIDs {
                        guard let snapshot = changeReviewProjectionStore.snapshot(for: proposalID) else {
                            continue
                        }

                        let pendingPaths = snapshot.fileChanges
                            .filter { $0.state.isPendingReview }
                            .map(\.relativePath)
                        guard !pendingPaths.isEmpty else {
                            continue
                        }

                        try await applyEngine.apply(proposalID: proposalID, approvedPaths: pendingPaths)
                    }

                case .discard:
                    let revertService = DraftRevertService(
                        modelContext: modelContext,
                        projectionStore: changeReviewProjectionStore
                    )
                    for proposalID in proposalIDs {
                        guard let snapshot = changeReviewProjectionStore.snapshot(for: proposalID) else {
                            continue
                        }

                        let pendingPaths = snapshot.fileChanges
                            .filter { $0.state.isPendingReview }
                            .map(\.relativePath)
                        guard !pendingPaths.isEmpty else {
                            continue
                        }

                        try await revertService.revertFiles(proposalID: proposalID, relativePaths: pendingPaths)
                    }
                }

                reconcileProposalSelectionAfterDockBatchAction(proposalIDs: proposalIDs)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func reconcileProposalSelectionAfterDockBatchAction(proposalIDs: [UUID]) {
        guard let selectedProposalID = workspaceState.selectedChangeProposalID,
              proposalIDs.contains(selectedProposalID) else {
            return
        }

        guard let snapshot = changeReviewProjectionStore.snapshot(for: selectedProposalID),
              snapshot.proposal.state.isPendingReview else {
            guard let nextProposalID = proposalDockPresentation.actionableProposalIDs.first,
                  let nextSnapshot = changeReviewProjectionStore.snapshot(for: nextProposalID) else {
                workspaceState.clearChangeProposalSelection()
                return
            }

            let nextPath = ChangeProposalReviewSelectionResolver.resolve(
                in: nextSnapshot,
                selectedFilePath: nil
            )?.relativePath
            workspaceState.selectChangeProposal(nextProposalID, filePath: nextPath)
            return
        }

        let nextPath = ChangeProposalReviewSelectionResolver.resolve(
            in: snapshot,
            selectedFilePath: workspaceState.selectedChangeProposalFilePath
        )?.relativePath
        workspaceState.selectChangeProposal(selectedProposalID, filePath: nextPath)
    }

    private enum ProposalDockBulkAction {
        case apply
        case discard
    }

    func contextChip(systemImage: String, label: String, tint: Color, onRemove: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tint)
            Text(label)
                .font(.body)
                .foregroundStyle(.primary.opacity(0.72))
                .lineLimit(1)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
var fileChipsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 8) {
                ForEach(attachedFiles) { file in
                    if file.isImage || file.isPDF {
                        FileThumbnailView(
                            file: file,
                            onRemove: { attachedFiles.removeAll { $0.id == file.id } },
                            onTap: { viewingMedia = MediaItem(url: file.url) }
                        )
                        .padding(.top, 4)
                    } else {
                        fileChip(file)
                            .padding(.top, 4)
                    }
                }
            }
            .padding(.bottom, 6)
        }
    }

    var inputDirectiveChipsRow: some View {
        HStack(spacing: 6) {
            ForEach(activeInputDirectives, id: \.id) { directive in
                inputDirectiveChip(directive)
            }
            Spacer(minLength: 0)
        }
    }

    func inputDirectiveChip(_ directive: ChatInputDirective) -> some View {
        let label: String
        switch directive {
        case .skill(let value):
            label = "Skill: \(value.displayName)"
        }

        return HStack(spacing: 4) {
            Image(systemName: "command")
                .font(.caption2)
                .foregroundStyle(Color.accentColor)
            Text(label)
                .font(.caption)
                .lineLimit(1)
            Button {
                activeInputDirectives.removeAll { $0.id == directive.id }
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    func fileChip(_ file: AttachedFile) -> some View {
        HStack(spacing: 4) {
            Image(systemName: fileIcon(for: file.name))
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(file.name)
                .font(.caption)
                .lineLimit(1)
            Button {
                attachedFiles.removeAll { $0.id == file.id }
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    func fileIcon(for name: String) -> String {
        FileIconSymbolResolver.symbol(forFileName: name)
    }

    var sendButton: some View {
        Group {
            if composerExecutionPresentation.showsSendButton && composerExecutionPresentation.showsStopButton {
                HStack(spacing: 8) {
                    if composerExecutionPresentation.showsStopButton {
                        Button {
                            stopStreaming()
                        } label: {
                            Image(systemName: "stop.circle.fill")
                                .font(.system(size: 16))
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("chat.stopButton")
                    }

                    Button {
                        activeTask = Task { await sendMessage() }
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(canSend ? Color.accentColor : Color.secondary.opacity(0.4))
                    }
                    .buttonStyle(.plain)
                    .disabled(composerExecutionPresentation.isSendDisabled)
                    .keyboardShortcut(.return, modifiers: .command)
                    .accessibilityIdentifier("chat.sendButton")
                }
            } else {
                if composerExecutionPresentation.showsStopButton {
                    Button {
                        stopStreaming()
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("chat.stopButton")
                }

                if composerExecutionPresentation.showsSendButton {
                    Button {
                        activeTask = Task { await sendMessage() }
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(canSend ? Color.accentColor : Color.secondary.opacity(0.4))
                    }
                    .buttonStyle(.plain)
                    .disabled(composerExecutionPresentation.isSendDisabled)
                    .keyboardShortcut(.return, modifiers: .command)
                    .accessibilityIdentifier("chat.sendButton")
                }
            }
        }
    }

    var canSend: Bool {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard sessionInteractionPolicy.canSend else { return false }

        let settings = AppSettings.getOrCreate(in: modelContext)
        return (sendReadinessError(settings: settings) ?? "") .isEmpty
    }

    // MARK: - File Drop

    func handleFileDrop(providers: [NSItemProvider]) -> Bool {
        print("[Drop] received \(providers.count) provider(s)")
        var handled = false
        for provider in providers {
            print("[Drop] hasFileURL=\(provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)) registeredTypes=\(provider.registeredTypeIdentifiers)")
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, error in
                    print("[Drop] loadItem item=\(String(describing: item)) type=\(type(of: item)) error=\(String(describing: error))")
                    let url: URL?
                    if let u = item as? URL {
                        url = u
                    } else if let nsurl = item as? NSURL, let u = nsurl as URL? {
                        url = u
                    } else if let data = item as? Data {
                        url = URL(dataRepresentation: data, relativeTo: nil)
                    } else {
                        print("[Drop] ⚠️ cannot extract URL from item")
                        url = nil
                    }
                    guard let url else { return }
                    print("[Drop] resolved URL: \(url.path)")
                    let file = AttachedFile(name: url.lastPathComponent, url: url)
                    DispatchQueue.main.async {
                        print("[Drop] appending file on main; current count=\(self.attachedFiles.count)")
                        if !self.attachedFiles.contains(where: { $0.url == url }) {
                            self.attachedFiles.append(file)
                            print("[Drop] ✅ attachedFiles.count=\(self.attachedFiles.count)")
                        }
                    }
                }
                handled = true
            }
        }
        return handled
    }

    // MARK: - @ Mention Popup

    @ViewBuilder
    var slashPopupCard: some View {
        ComposerAssistPanelContainer(accessibilityIdentifier: "chat.slashPopup") {
            if slashCandidates.isEmpty {
                HStack {
                    Text("没有匹配的命令")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            } else {
                ComposerSelectableList(
                    items: displayedSlashCandidates,
                    highlightedIndex: highlightedSlashIndex,
                    maximumHeight: 320,
                    autoScrollToHighlightedItem: true,
                    onSelect: selectSlashItem
                ) { item, isHighlighted in
                    slashRow(item: item, isHighlighted: isHighlighted)
                }
            }
        }
    }

    func slashRow(item: ChatSlashCommandItem, isHighlighted: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "command")
                .font(.system(size: 11))
                .foregroundStyle(Color.accentColor)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(item.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let badge = item.badge {
                        Text(badge)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    if item.isEnabledByDefault {
                        Text("已启用")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.green)
                    }
                }
                if !item.subtitle.isEmpty {
                    Text(item.subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(isHighlighted ? Color.accentColor.opacity(0.12) : .clear)
        )
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
    }

    @ViewBuilder
    var mentionPopupCard: some View {
        ComposerAssistPanelContainer(accessibilityIdentifier: "chat.mentionPopup") {
            ComposerSelectableList(
                items: displayedMentionCandidates,
                highlightedIndex: highlightedMentionIndex,
                onSelect: handleMentionSelection
            ) { url, isHighlighted in
                mentionRow(url: url, isHighlighted: isHighlighted)
            }
        }
    }

    @ViewBuilder
    var todoPopupCard: some View {
        ComposerAssistPanelContainer(accessibilityIdentifier: "chat.todoPopup") {
            InputAreaTodoCardView(presentation: todoCardPresentation, showsContainerChrome: false)
        }
    }

    func mentionRow(url: URL, isHighlighted: Bool) -> some View {
        let relPath: String = {
            guard !mentionWorkingDir.isEmpty,
                  url.path.hasPrefix(mentionWorkingDir + "/") else { return url.path }
            return String(url.path.dropFirst(mentionWorkingDir.count + 1))
        }()
        return HStack(spacing: 8) {
            Image(systemName: fileIcon(for: url.lastPathComponent))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(url.lastPathComponent)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if relPath != url.lastPathComponent {
                    Text(relPath)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(isHighlighted ? Color.accentColor.opacity(0.12) : .clear)
        )
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
    }

    // MARK: - @ Mention Logic

    func updateMentionState(_ text: String) {
        guard let query = detectMentionQuery(in: text) else {
            if mentionQuery != nil {
                withAnimation(.easeOut(duration: 0.12)) { mentionQuery = nil }
                mentionCandidates = []
                highlightedMentionIndex = nil
            }
            return
        }
        let wd = AppSettings.getOrCreate(in: modelContext).workingDirectory
        guard !wd.isEmpty else {
            mentionQuery = query
            mentionCandidates = []
            return
        }
        mentionQuery = query
        mentionWorkingDir = wd
        let baseURL = URL(fileURLWithPath: wd)
        Task.detached(priority: .userInitiated) {
            let all = Self.collectWorkspaceFiles(at: baseURL)
            let filtered: [URL] = query.isEmpty
                ? Array(all.prefix(10))
                : all.filter {
                    $0.lastPathComponent.localizedCaseInsensitiveContains(query) ||
                    $0.path.localizedCaseInsensitiveContains(query)
                  }.prefix(8).map { $0 }
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.1)) {
                    self.mentionCandidates = filtered
                    self.highlightedMentionIndex = filtered.isEmpty ? nil : 0
                }
            }
        }
    }

    func detectMentionQuery(in text: String) -> String? {
        guard let lastSep = text.lastIndex(where: { $0.isWhitespace || $0.isNewline }) else {
            guard text.hasPrefix("@") else { return nil }
            return String(text.dropFirst())
        }
        let afterSep = text.index(after: lastSep)
        guard afterSep < text.endIndex else { return nil }
        let word = String(text[afterSep...])
        guard word.hasPrefix("@") else { return nil }
        return String(word.dropFirst())
    }

    func insertMention(url: URL, relPath: String) {
        let query = mentionQuery ?? ""
        let target = "@\(query)"
        if let range = inputText.range(of: target, options: .backwards) {
            inputText.replaceSubrange(range, with: "@\(relPath)")
        }
        withAnimation(.easeOut(duration: 0.12)) { mentionQuery = nil }
        mentionCandidates = []
        highlightedMentionIndex = nil
    }

    func handleMentionSelection(_ url: URL) {
        let relPath: String = {
            guard !mentionWorkingDir.isEmpty,
                  url.path.hasPrefix(mentionWorkingDir + "/") else { return url.path }
            return String(url.path.dropFirst(mentionWorkingDir.count + 1))
        }()
        insertMention(url: url, relPath: relPath)
    }

    private var highlightedSlashIndex: Int? {
        guard let highlightedSlashItemID else { return displayedSlashCandidates.isEmpty ? nil : 0 }
        return displayedSlashCandidates.firstIndex(where: { $0.id == highlightedSlashItemID })
    }

    func updateComposerAssistState(_ text: String) {
        syncSlashState(with: text)

        if slashQuery != nil {
            debugSlashLog(
                "slash query active text=\(text.debugDescription) candidates=\(slashCandidates.count)"
            )
            ensureACPCommandsReadyForSlashQuery(text: text)
            if mentionQuery != nil {
                withAnimation(.easeOut(duration: 0.12)) { mentionQuery = nil }
                mentionCandidates = []
            }
            return
        }

        updateMentionState(text)
    }

    func syncSlashState(with text: String) {
        var state = ChatComposerSlashState(
            query: slashQuery,
            candidates: slashCandidates,
            highlightedItemID: highlightedSlashItemID
        )
        state.update(for: text, registry: chatSlashCommandRegistry)
        slashQuery = state.query
        slashCandidates = state.candidates
        highlightedSlashItemID = state.highlightedItemID
        debugSlashLog(
            "syncSlashState text=\(text.debugDescription) query=\(slashQuery ?? "nil") candidates=\(slashCandidates.map(\.title).joined(separator: ","))"
        )
    }

    var chatSlashCommandRegistry: ChatSlashCommandRegistry {
        let settings = AppSettings.getOrCreate(in: modelContext)
        let remoteCommandProviders: [any ChatSlashCommandProvider] = currentACPCommandProvider().map { [$0] } ?? []
        return ChatSlashCommandRegistry(
            providers: remoteCommandProviders + [
                SkillChatSlashCommandProvider(
                    skills: skillService.availableSkills,
                    enabledSkillNames: settings.enabledSkillNames
                )
            ]
        )
    }

    private func currentACPCommands() -> [ACPCommandDescriptor] {
        guard resolvedExecutionProviderID != .builtInAgent,
              let registry = claudeService.executionProviderRegistry,
              let provider = registry.provider(for: resolvedExecutionProviderID) as? ACPChatSlashCommandSource else {
            debugSlashLog("currentACPCommandProvider unavailable provider=\(resolvedExecutionProviderID.rawValue)")
            return []
        }

        let commands = provider.remoteCommands(localSessionID: session.sessionId)
        guard !commands.isEmpty else {
            debugSlashLog("currentACPCommandProvider empty remoteCommands")
            return []
        }
        debugSlashLog(
            "currentACPCommandProvider loaded count=\(commands.count) names=\(commands.map(\.name).joined(separator: ","))"
        )
        return commands
    }

    private func currentACPCommandProvider() -> ACPChatSlashCommandProvider? {
        let commands = currentACPCommands()
        guard !commands.isEmpty else {
            return nil
        }
        return ACPChatSlashCommandProvider(commands: commands)
    }

    private func ensureACPCommandsReadyForSlashQuery(text: String) {
        let hasRemoteACPCommands = !currentACPCommands().isEmpty
        guard ChatComposerACPWarmupPolicy.shouldWarmup(
            slashQuery: slashQuery,
            resolvedExecutionProviderID: resolvedExecutionProviderID,
            hasRemoteACPCommands: hasRemoteACPCommands,
            isWarmupInFlight: isACPCommandWarmupInFlight
        ) else {
            if slashQuery != nil {
                debugSlashLog(
                    "ensureACPCommandsReadyForSlashQuery skipped candidates=\(slashCandidates.count) hasRemoteACPCommands=\(hasRemoteACPCommands) warmupInFlight=\(isACPCommandWarmupInFlight) provider=\(resolvedExecutionProviderID.rawValue)"
                )
            }
            return
        }

        isACPCommandWarmupInFlight = true
        let providerID = resolvedExecutionProviderID
        debugSlashLog("ensureACPCommandsReadyForSlashQuery triggering warmup text=\(text.debugDescription)")

        Task {
            await claudeService.handleExecutionProviderSelectionChange(
                session: session,
                selectedProviderID: providerID,
                modelContext: modelContext
            )

            await MainActor.run {
                isACPCommandWarmupInFlight = false
                debugSlashLog("ensureACPCommandsReadyForSlashQuery warmup finished; re-syncing slash state")
                syncSlashState(with: text)
            }
        }
    }

    func handleComposerSelectionMove(delta: Int) -> Bool {
        if slashQuery != nil, !slashCandidates.isEmpty {
            var controller = ComposerAssistSelectionController(
                itemCount: displayedSlashCandidates.count,
                selectedIndex: highlightedSlashIndex
            )
            controller.move(delta: delta)
            if let selectedIndex = controller.selectedIndex,
               selectedIndex < displayedSlashCandidates.count {
                highlightedSlashItemID = displayedSlashCandidates[selectedIndex].id
            }
            return true
        }

        if mentionQuery != nil, !mentionCandidates.isEmpty {
            var controller = ComposerAssistSelectionController(
                itemCount: displayedMentionCandidates.count,
                selectedIndex: highlightedMentionIndex
            )
            controller.move(delta: delta)
            highlightedMentionIndex = controller.selectedIndex
            return true
        }

        return false
    }

    func commitComposerSelection() -> Bool {
        if slashQuery != nil {
            guard let selected = slashCandidates.first(where: { $0.id == highlightedSlashItemID }) ?? slashCandidates.first else {
                return false
            }
            selectSlashItem(selected)
            return true
        }

        if mentionQuery != nil,
           let highlightedMentionIndex,
           highlightedMentionIndex < displayedMentionCandidates.count {
            handleMentionSelection(displayedMentionCandidates[highlightedMentionIndex])
            return true
        }

        return false
    }

    func cancelComposerAssist() -> Bool {
        var handled = false
        if slashQuery != nil {
            clearSlashState()
            handled = true
        }
        if mentionQuery != nil {
            withAnimation(.easeOut(duration: 0.12)) { mentionQuery = nil }
            mentionCandidates = []
            highlightedMentionIndex = nil
            handled = true
        }
        return handled
    }

    func clearSlashState() {
        slashQuery = nil
        slashCandidates = []
        highlightedSlashItemID = nil
    }

    func selectSlashItem(_ item: ChatSlashCommandItem) {
        let result = ChatInputCommandParser.replacingSlashToken(in: inputText, selectedItem: item)
        inputText = result.updatedText
        if let directive = result.directive {
            activeInputDirectives = [directive]
        }
        clearSlashState()
    }

    nonisolated static func collectWorkspaceFiles(at url: URL, depth: Int = 0) -> [URL] {
        guard depth < 6 else { return [] }
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles
        ) else { return [] }
        var results: [URL] = []
        for item in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir { results += collectWorkspaceFiles(at: item, depth: depth + 1) }
            else { results.append(item) }
        }
        return results
    }
}

// MARK: - MentionAwareEditor

/// NSTextView subclass that intercepts file URL drops and forwards them via a callback,
/// preventing the text view from consuming drops meant for the outer SwiftUI drop target.
private final class FileForwardingTextView: NSTextView {
    var onFileDropped: (([URL]) -> Void)?
    var onMoveSelection: ((Int) -> Bool)?
    var onCommitSelection: (() -> Bool)?
    var onCancelAssist: (() -> Bool)?

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self],
                                                   options: [.urlReadingFileURLsOnly: true]) {
            return .copy
        }
        return super.draggingEntered(sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self],
                                                   options: [.urlReadingFileURLsOnly: true]) {
            return true
        }
        return super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let raw = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        )
        let urls = raw?.compactMap { ($0 as? NSURL) as URL? } ?? []
        guard !urls.isEmpty else { return super.performDragOperation(sender) }
        DispatchQueue.main.async { [weak self] in self?.onFileDropped?(urls) }
        return true
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.isEmpty {
            switch event.keyCode {
            case 125:
                if onMoveSelection?(1) == true { return }
            case 126:
                if onMoveSelection?(-1) == true { return }
            case 36, 48, 76:
                if onCommitSelection?() == true { return }
            case 53:
                if onCancelAssist?() == true { return }
            default:
                break
            }
        }
        super.keyDown(with: event)
    }
}

/// NSTextView-backed text editor that highlights @mention tokens with accent-color styling.
private struct MentionAwareEditor: NSViewRepresentable {

    @Binding var text: String
    @Binding var height: CGFloat
    var isDisabled: Bool = false
    var onTextChange: (String) -> Void = { _ in }
    var onMoveSelection: (Int) -> Bool = { _ in false }
    var onCommitSelection: () -> Bool = { false }
    var onCancelAssist: () -> Bool = { false }
    var onFileDrop: ([URL]) -> Void = { _ in }

    // MARK: Base attributes

    static let baseAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
        .foregroundColor: NSColor.labelColor
    ]

    private final class ComposerScrollView: NSScrollView {
        var onWidthChange: (() -> Void)?
        private var lastMeasuredWidth: CGFloat = 0

        override func layout() {
            super.layout()

            let width = contentSize.width
            guard abs(width - lastMeasuredWidth) > 1 else {
                return
            }

            lastMeasuredWidth = width
            onWidthChange?()
        }
    }

    // MARK: NSViewRepresentable

    func makeNSView(context: Context) -> NSScrollView {
        let tv = FileForwardingTextView()
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.allowsUndo = true
        tv.font = .systemFont(ofSize: NSFont.systemFontSize)
        tv.textColor = .labelColor
        tv.backgroundColor = .clear
        tv.drawsBackground = false
        tv.textContainerInset = NSSize(
            width: 0,
            height: ChatSurfaceLayoutMetrics.composerTextContainerVerticalInset
        )
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.typingAttributes = Self.baseAttributes
        tv.onFileDropped = onFileDrop
        tv.onMoveSelection = onMoveSelection
        tv.onCommitSelection = onCommitSelection
        tv.onCancelAssist = onCancelAssist

        let scrollView = ComposerScrollView()
        scrollView.documentView = tv
        scrollView.backgroundColor = .clear
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.onWidthChange = {
            context.coordinator.recalculateHeight(tv, force: true)
        }
        DispatchQueue.main.async {
            context.coordinator.recalculateHeight(tv, force: true)
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let tv = scrollView.documentView as? FileForwardingTextView else { return }
        context.coordinator.parent = self
        tv.isEditable = !isDisabled
        tv.onFileDropped = onFileDrop
        tv.onMoveSelection = onMoveSelection
        tv.onCommitSelection = onCommitSelection
        tv.onCancelAssist = onCancelAssist
        let didUpdateText = tv.string != text
        if tv.string != text {
            let sel = tv.selectedRanges
            tv.string = text
            tv.selectedRanges = sel
            Self.applyMentionStyling(to: tv)
        }
        context.coordinator.recalculateHeight(tv, force: didUpdateText)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    // MARK: Styling

    static func applyMentionStyling(to tv: NSTextView) {
        guard let storage = tv.textStorage else { return }
        let fullRange = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.setAttributes(baseAttributes, range: fullRange)
        if let regex = try? NSRegularExpression(pattern: #"@\S+"#) {
            for match in regex.matches(in: storage.string, range: fullRange) {
                storage.addAttributes([
                    .foregroundColor: NSColor.controlAccentColor,
                    .backgroundColor: NSColor.controlAccentColor.withAlphaComponent(0.12)
                ], range: match.range)
            }
        }
        storage.endEditing()
        // Reset typing attributes so newly typed text after a mention token uses base style
        tv.typingAttributes = baseAttributes
    }

    // MARK: Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MentionAwareEditor
        private var lastMeasuredWidth: CGFloat = 0
        private var lastMeasuredText = ""
        init(_ parent: MentionAwareEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
            parent.onTextChange(tv.string)
            recalculateHeight(tv, force: true)
            // Apply styling async to avoid mutating storage during its own edit cycle
            DispatchQueue.main.async { [weak tv] in
                guard let tv else { return }
                MentionAwareEditor.applyMentionStyling(to: tv)
            }
        }

        func recalculateHeight(_ textView: NSTextView, force: Bool = false) {
            guard let scrollView = textView.enclosingScrollView,
                  let textContainer = textView.textContainer,
                  let layoutManager = textView.layoutManager else {
                return
            }

            let measuredWidth = scrollView.contentSize.width
            if !force,
               abs(lastMeasuredWidth - measuredWidth) < 1,
               lastMeasuredText == textView.string {
                return
            }

            lastMeasuredWidth = measuredWidth
            lastMeasuredText = textView.string

            layoutManager.ensureLayout(for: textContainer)
            let lineHeight = layoutManager.defaultLineHeight(
                for: textView.font ?? .systemFont(ofSize: NSFont.systemFontSize)
            )
            let usedRect = layoutManager.usedRect(for: textContainer)
            let extraLineFragmentHeight: CGFloat
            if textView.string.last.map({ $0.isNewline }) == true {
                extraLineFragmentHeight = layoutManager.extraLineFragmentRect.height
            } else {
                extraLineFragmentHeight = 0
            }
            let measuredTextHeight = usedRect.height + extraLineFragmentHeight
            let unclampedHeight = ceil(
                measuredTextHeight +
                ChatSurfaceLayoutMetrics.composerTextContainerVerticalInset * 2 +
                ChatSurfaceLayoutMetrics.composerHeightChromePadding
            )
            let resolvedHeight = ChatSurfaceLayoutMetrics.composerHeight(
                text: textView.string,
                measuredTextHeight: measuredTextHeight,
                lineHeight: lineHeight
            )

            scrollView.hasVerticalScroller = unclampedHeight > resolvedHeight + 0.5

            if abs(parent.height - resolvedHeight) > 0.5 {
                parent.height = resolvedHeight
            }
        }
    }
}
