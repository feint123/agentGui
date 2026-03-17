import SwiftUI

struct TerminalScreenView: View {
    let snapshot: TerminalScreenSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                screenBadge(snapshot.activeBuffer == .alternate ? "Alternate" : "Primary")
                screenBadge("\(snapshot.width)x\(snapshot.height)")
                Spacer(minLength: 0)
                Text("\(snapshot.cursor.row + 1):\(snapshot.cursor.column + 1)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            }

            ScrollView([.horizontal, .vertical], showsIndicators: true) {
                Text(verbatim: Self.displayText(for: snapshot))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(10)
                    .accessibilityIdentifier("terminal.screen.text")
            }
            .frame(minHeight: 140, maxHeight: 220)
            .background(Color.primary.opacity(0.04))
            .clipShape(.rect(cornerRadius: 8))
        }
        .accessibilityIdentifier("terminal.screen")
    }

    static func displayText(for snapshot: TerminalScreenSnapshot) -> String {
        snapshot.plainTextLines.joined(separator: "\n")
    }

    @ViewBuilder
    private func screenBadge(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.primary.opacity(0.05))
            .clipShape(.capsule)
    }
}

struct ManagedTerminalScreenDetailView: View {
    @Environment(ClaudeService.self) private var claudeService

    let toolCall: ToolCall

    @State private var snapshot: TerminalScreenSnapshot?
    @State private var loadError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("终端屏幕")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            Group {
                if let snapshot {
                    TerminalScreenView(snapshot: snapshot)
                } else if let fallback = fallbackText {
                    ScrollView([.horizontal, .vertical], showsIndicators: true) {
                        Text(verbatim: fallback)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: true, vertical: true)
                            .padding(10)
                    }
                    .frame(minHeight: 140, maxHeight: 220)
                    .background(Color.primary.opacity(0.04))
                    .clipShape(.rect(cornerRadius: 8))
                    .accessibilityIdentifier("terminal.screen.placeholder")
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 140)
                }
            }
        }
        .accessibilityIdentifier("toolDetail.terminalScreen")
        .task(id: refreshContextKey) {
            await refreshLoop()
        }
    }

    private var refreshContextKey: String {
        [toolCall.terminalSessionID ?? "", toolCall.terminalTaskId ?? "", toolCall.terminalTaskStatus ?? ""].joined(separator: "|")
    }

    private var fallbackText: String? {
        if let loadError, snapshot == nil {
            return loadError
        }
        if let prompt = toolCall.terminalPromptSummary?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty {
            return prompt
        }
        if let terminalOutput = toolCall.terminalOutput?.trimmingCharacters(in: .whitespacesAndNewlines), !terminalOutput.isEmpty {
            return terminalOutput
        }
        return nil
    }

    private func refreshLoop() async {
        guard let sessionId = toolCall.terminalSessionID,
              let taskId = toolCall.terminalTaskId else {
            return
        }

        let runtime = claudeService.getTerminalTaskRuntime(for: sessionId, workingDirectory: nil)

        while !Task.isCancelled {
            do {
                let latestSnapshot = try await runtime.screenSnapshot(taskId: taskId)
                await MainActor.run {
                    snapshot = latestSnapshot
                    loadError = nil
                }
            } catch {
                await MainActor.run {
                    if snapshot == nil {
                        loadError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    }
                }
            }

            if let status = toolCall.terminalTaskStatus.flatMap(TerminalTaskStatus.init(rawValue:)), status.isTerminal {
                break
            }

            do {
                try await Task.sleep(nanoseconds: 350_000_000)
            } catch {
                break
            }
        }
    }
}