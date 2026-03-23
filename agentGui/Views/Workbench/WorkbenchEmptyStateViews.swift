import SwiftUI

struct WorkbenchSidebarEmptyStateView<Actions: View>: View {
    let systemImage: String
    let title: String
    let message: String
    let actions: Actions

    init(systemImage: String, title: String, message: String) where Actions == EmptyView {
        self.systemImage = systemImage
        self.title = title
        self.message = message
        self.actions = EmptyView()
    }

    init(
        systemImage: String,
        title: String,
        message: String,
        @ViewBuilder actions: () -> Actions
    ) {
        self.systemImage = systemImage
        self.title = title
        self.message = message
        self.actions = actions()
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)

            VStack(spacing: 4) {
                Text(title)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)

                Text(message)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }

            actions
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct WorkbenchConversationEmptyStateCard: View {
    let action: () -> Void
    let buttonAccessibilityIdentifier: String?

    init(action: @escaping () -> Void, buttonAccessibilityIdentifier: String? = nil) {
        self.action = action
        self.buttonAccessibilityIdentifier = buttonAccessibilityIdentifier
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 14) {
                ZStack {
                    Circle()
                        .fill(Color.accentColor.opacity(0.16))
                        .frame(width: 52, height: 52)

                    Image(systemName: "bubble.left.and.bubble.right.fill")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("会话")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Text("从这里开始第一段对话")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)
                }
            }

            Text("新会话会保存在本地，按最近活动自动排序，后续也可以搜索、重命名或复制为本地工作分支。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                WorkbenchConversationEmptyStateTag(systemImage: "internaldrive", text: "本地保存")
                WorkbenchConversationEmptyStateTag(systemImage: "clock.arrow.circlepath", text: "最近活动")
                WorkbenchConversationEmptyStateTag(systemImage: "magnifyingglass", text: "快速搜索")
            }

            Button(action: action) {
                Label("新建对话", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .applyAccessibilityIdentifier(buttonAccessibilityIdentifier)

            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                Text("创建后会自动进入当前工作台。")
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.accentColor.opacity(0.10),
                            Color.primary.opacity(0.03)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 0.8)
        }
        .shadow(color: .black.opacity(0.10), radius: 18, y: 10)
    }
}

private struct WorkbenchConversationEmptyStateTag: View {
    let systemImage: String
    let text: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.04), in: Capsule())
    }
}

private extension View {
    @ViewBuilder
    func applyAccessibilityIdentifier(_ identifier: String?) -> some View {
        if let identifier {
            accessibilityIdentifier(identifier)
        } else {
            self
        }
    }
}