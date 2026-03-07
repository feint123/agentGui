//
//  ChatView+InputArea.swift
//  agentGui
//

import SwiftUI
import UniformTypeIdentifiers
import AppKit

extension ChatView {

    // MARK: - Input Area

    var inputArea: some View {
        VStack(spacing: 0) {
            if mentionQuery != nil && !mentionCandidates.isEmpty {
                mentionPopupCard
            }
            Divider()
                .opacity(0.5)

            VStack(spacing: 8) {
                if !attachedFiles.isEmpty {
                    fileChipsRow
                }

                HStack(alignment: .bottom, spacing: 10) {
                    MentionAwareEditor(
                        text: $inputText,
                        isDisabled: claudeService.isStreaming,
                        onTextChange: { updateMentionState($0) },
                        onFileDrop: { urls in
                            for url in urls {
                                guard !attachedFiles.contains(where: { $0.url == url }) else { continue }
                                attachedFiles.append(AttachedFile(name: url.lastPathComponent, url: url))
                            }
                        }
                    )
                    .frame(minHeight: 28, maxHeight: 130)
                    .padding(.horizontal, 4)

                    sendButton
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(.regularMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(
                                isDropTargeted
                                    ? Color.accentColor.opacity(0.6)
                                    : Color.primary.opacity(0.08),
                                lineWidth: isDropTargeted ? 2 : 1
                            )
                    )
                    .shadow(color: .black.opacity(0.06), radius: 8, y: -2)
            )
            .padding(.horizontal, 16)
        .padding(.bottom, 6)
        .padding(.top, 8)
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
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "swift": return "swift"
        case "py": return "doc.text"
        case "js", "ts": return "doc.text"
        case "json": return "curlybraces"
        case "md": return "doc.richtext"
        case "png", "jpg", "jpeg", "gif", "svg": return "photo"
        default: return "doc"
        }
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
            }
        }
    }

    var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && claudeService.isConfigured
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
    var mentionPopupCard: some View {
        VStack(spacing: 0) {
            ForEach(Array(mentionCandidates.prefix(8)), id: \.self) { url in
                mentionRow(url: url)
            }
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.10), radius: 8, y: -2)
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
}

/// NSTextView-backed text editor that highlights @mention tokens with accent-color styling.
private struct MentionAwareEditor: NSViewRepresentable {

    @Binding var text: String
    var isDisabled: Bool = false
    var onTextChange: (String) -> Void = { _ in }
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
