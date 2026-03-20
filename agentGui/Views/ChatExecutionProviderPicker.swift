import SwiftUI

struct ChatExecutionProviderPicker: View {
    @Binding var selection: ConversationExecutionProviderID
    let copilotAvailabilityStatus: GitHubCopilotCLIAvailabilityStatus

    var body: some View {
        Menu {
            Button("内置 Agent") {
                selection = .builtInAgent
            }

            Button("GitHub Copilot CLI") {
                selection = .githubCopilotCLI
            }
            .disabled(copilotAvailabilityStatus.kind != .available)
        } label: {
            Label("\(selection.displayName)", systemImage: "bolt.horizontal.circle")
                .font(.caption)
        }
        .pickerStyle(.menu)
        .controlSize(.small)
        .accessibilityIdentifier("chat.executionProviderPicker")
    }
}