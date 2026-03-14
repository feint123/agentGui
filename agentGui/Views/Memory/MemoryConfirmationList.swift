import SwiftUI

struct MemoryConfirmationList: View {
    let candidates: [MemoryConfirmationCandidate]
    let onApprove: (MemoryConfirmationCandidate) async -> Void
    let onReject: (MemoryConfirmationCandidate) -> Void

    var body: some View {
        if candidates.isEmpty {
            ContentUnavailableView("暂无待确认写入", systemImage: "checkmark.bubble")
        } else {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(candidates) { candidate in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(candidate.title)
                                    .font(.headline)
                                Text(candidate.scope.namespace)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Text(relativeDateString(candidate.createdAt))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }

                        Text(candidate.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(candidate.reason)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        HStack {
                            Button("批准") {
                                Task {
                                    await onApprove(candidate)
                                }
                            }
                            .buttonStyle(.borderedProminent)

                            Button("拒绝") {
                                onReject(candidate)
                            }
                            .buttonStyle(.bordered)

                            Spacer()
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.orange.opacity(0.18), lineWidth: 1)
                    )
                }
            }
        }
    }

    private func relativeDateString(_ date: Date) -> String {
        date.formatted(.relative(presentation: .named))
    }
}