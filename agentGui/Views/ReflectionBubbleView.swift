import SwiftUI

struct ReflectionBubbleView: View {
    let presentation: ReflectionStepPresentation

    @State private var isExpanded: Bool
    @State private var hasManualOverride = false

    init(presentation: ReflectionStepPresentation) {
        self.presentation = presentation
        _isExpanded = State(initialValue: presentation.isExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isExpanded {
                Divider().opacity(0.12)
                content
            }
        }
        .background(Color.orange.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.orange.opacity(0.16), lineWidth: 1)
        )
        .onChange(of: presentation.isExpanded) { _, newValue in
            if !hasManualOverride {
                isExpanded = newValue
            }
        }
    }

    private var header: some View {
        Button {
            withAnimation(.spring(duration: 0.25)) {
                hasManualOverride = true
                isExpanded.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                Text(presentation.summaryText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Image(systemName: presentation.retryRecommended ? "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90" : "checkmark.circle")
                    .font(.caption2)
                    .foregroundStyle(presentation.retryRecommended ? .orange : .secondary)
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
    }

    private var content: some View {
        ScrollView(.vertical, showsIndicators: true) {
            Text(presentation.content)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
        }
        .frame(maxHeight: 180)
    }
}