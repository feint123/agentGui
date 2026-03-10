import SwiftUI

struct MemoryConfirmationList: View {
    let candidates: [MemoryConfirmationCandidate]

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
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
    }
}