//
//  ChatView+InputArea.swift
//  agentGui
//

import SwiftUI
import UniformTypeIdentifiers
import AppKit

extension ChatView {

    private var testLaunchOptions: TestLaunchOptions {
        TestLaunchOptions.current
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
                    ChatExecutionProviderPicker(
                        selection: executionProviderSelectionBinding,
                        copilotAvailabilityStatus: copilotComposerAvailabilityStatus
                    )

                    composerExecutionPreferencesControls

                    if resolvedExecutionProviderID == .githubCopilotCLI,
                       copilotComposerAvailabilityStatus.kind != .available {
                        Text(copilotComposerAvailabilityStatus.summaryText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }

                    Spacer(minLength: 0)
                }

                HStack(alignment: .bottom, spacing: 10) {
                    MentionAwareEditor(
                        text: $inputText,
                        isDisabled: claudeService.isStreaming,
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
                    .frame(minHeight: 28, maxHeight: 130)
                    .padding(.horizontal, 4)
                    .accessibilityIdentifier("chat.inputField")

                    sendButton
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .glassEffect(isDropTargeted ? .regular.interactive().tint(Color.accentColor.opacity(0.3)): .regular,
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
    }
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
        case .githubCopilotCLI:
            ExecutionOptionPicker(
                title: "",
                options: GitHubCopilotCLIConfiguration.modelOptions(
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
            if claudeService.isStreaming {
                Button {
                    stopStreaming()
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("chat.stopButton")
            } else {
                Button {
                    activeTask = Task { await sendMessage() }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(canSend ? Color.accentColor : Color.secondary.opacity(0.4))
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .keyboardShortcut(.return, modifiers: .command)
                .accessibilityIdentifier("chat.sendButton")
            }
        }
    }

    var canSend: Bool {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

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
        VStack(spacing: 0) {
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
                ForEach(Array(slashCandidates.prefix(8))) { item in
                    slashRow(item: item)
                }
            }
        }
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
        .accessibilityIdentifier("chat.slashPopup")
        .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .bottom)))
    }

    func slashRow(item: ChatSlashCommandItem) -> some View {
        let isHighlighted = item.id == highlightedSlashItemID
        return Button {
            selectSlashItem(item)
        } label: {
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
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
    }

    @ViewBuilder
    var mentionPopupCard: some View {
        VStack(spacing: 0) {
            ForEach(Array(mentionCandidates.prefix(8)), id: \.self) { url in
                mentionRow(url: url)
            }
        }
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
        .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .bottom)))
    }

    @ViewBuilder
    var todoPopupCard: some View {
        InputAreaTodoCardView(presentation: todoCardPresentation)
            .padding(.horizontal, 16)
            .padding(.bottom, 4)
            .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .bottom)))
    }

    func mentionRow(url: URL) -> some View {
        let relPath: String = {
            guard !mentionWorkingDir.isEmpty,
                  url.path.hasPrefix(mentionWorkingDir + "/") else { return url.path }
            return String(url.path.dropFirst(mentionWorkingDir.count + 1))
        }()
        return Button {
            insertMention(url: url, relPath: relPath)
        } label: {
            HStack(spacing: 8) {
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
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - @ Mention Logic

    func updateMentionState(_ text: String) {
        guard let query = detectMentionQuery(in: text) else {
            if mentionQuery != nil {
                withAnimation(.easeOut(duration: 0.12)) { mentionQuery = nil }
                mentionCandidates = []
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
    }

    func updateComposerAssistState(_ text: String) {
        syncSlashState(with: text)

        if slashQuery != nil {
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
    }

    var chatSlashCommandRegistry: ChatSlashCommandRegistry {
        let settings = AppSettings.getOrCreate(in: modelContext)
        return ChatSlashCommandRegistry(
            providers: [
                SkillChatSlashCommandProvider(
                    skills: skillService.availableSkills,
                    enabledSkillNames: settings.enabledSkillNames
                )
            ]
        )
    }

    func handleComposerSelectionMove(delta: Int) -> Bool {
        guard slashQuery != nil, !slashCandidates.isEmpty else { return false }
        var state = ChatComposerSlashState(
            query: slashQuery,
            candidates: slashCandidates,
            highlightedItemID: highlightedSlashItemID
        )
        state.moveSelection(delta: delta)
        highlightedSlashItemID = state.highlightedItemID
        return true
    }

    func commitComposerSelection() -> Bool {
        if slashQuery != nil {
            guard let selected = slashCandidates.first(where: { $0.id == highlightedSlashItemID }) ?? slashCandidates.first else {
                return false
            }
            selectSlashItem(selected)
            return true
        }

        if let firstMention = mentionCandidates.first, mentionQuery != nil {
            let relPath: String = {
                guard !mentionWorkingDir.isEmpty,
                      firstMention.path.hasPrefix(mentionWorkingDir + "/") else { return firstMention.path }
                return String(firstMention.path.dropFirst(mentionWorkingDir.count + 1))
            }()
            insertMention(url: firstMention, relPath: relPath)
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
        tv.textContainerInset = NSSize(width: 0, height: 3)
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.typingAttributes = Self.baseAttributes
        tv.onFileDropped = onFileDrop
        tv.onMoveSelection = onMoveSelection
        tv.onCommitSelection = onCommitSelection
        tv.onCancelAssist = onCancelAssist

        let scrollView = NSScrollView()
        scrollView.documentView = tv
        scrollView.backgroundColor = .clear
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let tv = scrollView.documentView as? FileForwardingTextView else { return }
        tv.isEditable = !isDisabled
        tv.onFileDropped = onFileDrop
        tv.onMoveSelection = onMoveSelection
        tv.onCommitSelection = onCommitSelection
        tv.onCancelAssist = onCancelAssist
        if tv.string != text {
            let sel = tv.selectedRanges
            tv.string = text
            tv.selectedRanges = sel
            Self.applyMentionStyling(to: tv)
        }
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
        init(_ parent: MentionAwareEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
            parent.onTextChange(tv.string)
            // Apply styling async to avoid mutating storage during its own edit cycle
            DispatchQueue.main.async { [weak tv] in
                guard let tv else { return }
                MentionAwareEditor.applyMentionStyling(to: tv)
            }
        }
    }
}
