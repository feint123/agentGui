import SwiftUI

struct MemoryRuntimeSnapshotRecordList: View {
    let title: String
    let records: [MemoryRuntimeSnapshotRecord]
    var showExclusionReason: Bool = false

    var body: some View {
        GroupBox(title) {
            VStack(alignment: .leading, spacing: 10) {
                if records.isEmpty {
                    Text("暂无数据")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(records) { record in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .top) {
                                Text(record.title)
                                    .font(.caption)
                                    .fontWeight(.medium)
                                Spacer()
                                Text(record.layer.rawValue)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }

                            if !record.summary.isEmpty {
                                Text(record.summary)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }

                            Text(metaLine(for: record))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)

                            if showExclusionReason, let exclusionReason = record.exclusionReason {
                                Text("排除原因：\(exclusionReason.rawValue)")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)

                        if record.id != records.last?.id {
                            Divider().opacity(0.2)
                        }
                    }
                }
            }
        }
    }

    private func metaLine(for record: MemoryRuntimeSnapshotRecord) -> String {
        [
            record.kind.rawValue,
            record.scope.namespace,
            record.verificationStatus.rawValue,
            record.sourceLabel,
            "chars=\(record.estimatedPromptChars)"
        ]
        .joined(separator: " · ")
    }
}