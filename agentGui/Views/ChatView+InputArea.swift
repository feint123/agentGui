//
//  ChatView+InputArea.swift
//  agentGui
//

import SwiftUI
import UniformTypeIdentifiers

extension ChatView {

    // MARK: - Input Area

    var inputArea: some View {
        VStack(spacing: 0) {
            Divider()
                .opacity(0.5)

            VStack(spacing: 8) {
                if !attachedFiles.isEmpty {
                    fileChipsRow
                }

                HStack(alignment: .bottom, spacing: 10) {
                    TextEditor(text: $inputText)
                        .focused($isInputFocused)
                        .scrollContentBackground(.hidden)
                        .background(Color.clear)
                        .frame(minHeight: 28, maxHeight: 130)
                        .padding(.horizontal, 4)
                        .disabled(claudeService.isStreaming)

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
            .padding(.bottom, 16)
            .padding(.top, 8)
            .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted) { providers in
                handleFileDrop(providers: providers)
            }
        }
        .background(.bar)
    }

    var fileChipsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(attachedFiles) { file in
                    fileChip(file)
                }
            }
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
        Button {
            Task { await sendMessage() }
        } label: {
            if claudeService.isStreaming {
                ProgressView()
                    .scaleEffect(0.7)
                    .frame(width: 30, height: 30)
            } else {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(canSend ? Color.accentColor : Color.secondary.opacity(0.4))
            }
        }
        .buttonStyle(.plain)
        .disabled(!canSend || claudeService.isStreaming)
        .keyboardShortcut(.return, modifiers: .command)
    }

    var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && claudeService.isConfigured
    }

    // MARK: - File Drop

    func handleFileDrop(providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                    guard let data = item as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                    let file = AttachedFile(name: url.lastPathComponent, url: url)
                    DispatchQueue.main.async {
                        if !self.attachedFiles.contains(where: { $0.url == url }) {
                            self.attachedFiles.append(file)
                        }
                    }
                }
                handled = true
            }
        }
        return handled
    }
}
