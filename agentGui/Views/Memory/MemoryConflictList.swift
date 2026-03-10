import SwiftUI

struct MemoryConflictList: View {
    let records: [MemoryRecord]

    var body: some View {
        if records.isEmpty {
            ContentUnavailableView("暂无冲突 / 替代记录", systemImage: "arrow.triangle.2.circlepath")
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(records) { record in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(record.title)
                            .font(.headline)
                        Text(record.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let supersededBy = record.supersededBy {
                            Text("已被替代为：\(supersededBy)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
    }
}