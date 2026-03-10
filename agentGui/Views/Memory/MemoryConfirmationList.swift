import SwiftUI

struct MemoryConfirmationList: View {
    let candidates: [MemoryConfirmationCandidate]
    let onApprove: (MemoryConfirmationCandidate) async -> Void
    let onReject: (MemoryConfirmationCandidate) -> Void

    var body: some View {
        if candidates.isEmpty {
            ContentUnavailableView("暂无待确认写入", systemImage: "checkmark.bubble")
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(candidates) { candidate in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(candidate.title)
                            .font(.headline)
                        Text(candidate.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(candidate.reason)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
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
                        }
                        .padding(.top, 4)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
    }
}