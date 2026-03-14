import SwiftUI

struct MemoryConflictList: View {
    let records: [MemoryRecord]

    var body: some View {
        if records.isEmpty {
            ContentUnavailableView("暂无冲突 / 替代记录", systemImage: "arrow.triangle.2.circlepath")
        } else {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(records) { record in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(record.title)
                                    .font(.headline)
                                Text(record.scope.namespace)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Text(record.lifecycleTier.rawValue.capitalized)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.secondary.opacity(0.1), in: Capsule())
                        }

                        Text(record.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let supersededBy = record.supersededBy {
                            Text("已被替代为：\(supersededBy)")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.primary.opacity(0.05), lineWidth: 1)
                    )
                }
            }
        }
    }
}