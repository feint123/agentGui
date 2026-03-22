import SwiftUI

struct ComposerAssistPanelContainer<Content: View, Accessory: View>: View {
    let title: String?
    let subtitle: String?
    let accessibilityIdentifier: String
    @ViewBuilder let accessory: Accessory
    @ViewBuilder let content: Content

    init(
        title: String? = nil,
        subtitle: String? = nil,
        accessibilityIdentifier: String,
        @ViewBuilder accessory: () -> Accessory,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.accessibilityIdentifier = accessibilityIdentifier
        self.accessory = accessory()
        self.content = content()
    }

    init(
        title: String? = nil,
        subtitle: String? = nil,
        accessibilityIdentifier: String,
        @ViewBuilder content: () -> Content
    ) where Accessory == EmptyView {
        self.init(
            title: title,
            subtitle: subtitle,
            accessibilityIdentifier: accessibilityIdentifier,
            accessory: { EmptyView() },
            content: content
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if title != nil || subtitle != nil {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        if let title {
                            Text(title)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.primary)
                        }
                        if let subtitle, !subtitle.isEmpty {
                            Text(subtitle)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer(minLength: 0)
                    accessory
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 8)
            }

            content
        }
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
        .accessibilityIdentifier(accessibilityIdentifier)
        .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .bottom)))
    }
}