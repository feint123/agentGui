import SwiftUI

struct ExecutionDigestView: View {
    let presentation: ExecutionDigestPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(presentation.headline)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            if let risk = presentation.outstandingRisk, !risk.isEmpty {
                Text(risk)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.02))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("chat.agentMessage.executionDigest")
    }
}