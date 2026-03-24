import SwiftUI

enum WorkbenchSidebarPanelStyle {
    static let layoutPadding: CGFloat = 10
    static let compactSpacing: CGFloat = 8
    static let sectionSpacing: CGFloat = 10
    static let headerBottomPadding: CGFloat = 8
    static let settingsRowSpacing: CGFloat = 12
    static let settingsToggleColumnWidth: CGFloat = 44
    static let controlHeight: CGFloat = 30
    static let controlCornerRadius: CGFloat = 12
    static let cardCornerRadius: CGFloat = 16
    static let cardPadding: CGFloat = 14
}

struct WorkbenchSidebarPanelHeader<Leading: View, Trailing: View>: View {
    let leading: Leading
    let trailing: Trailing

    init(
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) {
        self.leading = leading()
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: WorkbenchSidebarPanelStyle.compactSpacing) {
            leading
                .frame(maxWidth: .infinity, alignment: .leading)

            trailing
        }
        .padding(.horizontal, WorkbenchSidebarPanelStyle.layoutPadding)
        .padding(.top, WorkbenchSidebarPanelStyle.layoutPadding)
        .padding(.bottom, WorkbenchSidebarPanelStyle.headerBottomPadding)
    }
}

struct WorkbenchSidebarToolbarHeader<Leading: View, Trailing: View>: View {
    let leading: Leading
    let trailing: Trailing

    init(
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) {
        self.leading = leading()
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: WorkbenchSidebarPanelStyle.compactSpacing) {
            leading
                .frame(maxWidth: .infinity, alignment: .leading)

            trailing
        }
        .workbenchSidebarHeaderFieldStyle()
    }
}

struct WorkbenchSidebarPanelScrollView<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WorkbenchSidebarPanelStyle.sectionSpacing) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, WorkbenchSidebarPanelStyle.layoutPadding)
            .padding(.bottom, WorkbenchSidebarPanelStyle.layoutPadding)
        }
        .scrollIndicators(.hidden)
    }
}

struct WorkbenchSidebarSectionCard<Content: View, Accessory: View>: View {
    let title: String?
    let systemImage: String?
    let content: Content
    let accessory: Accessory
    let showsAccessory: Bool

    init(
        title: String? = nil,
        systemImage: String? = nil,
        @ViewBuilder content: () -> Content,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
        self.accessory = accessory()
        self.showsAccessory = true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSidebarPanelStyle.compactSpacing) {
            if title != nil || systemImage != nil || showsAccessory {
                HStack(alignment: .firstTextBaseline, spacing: WorkbenchSidebarPanelStyle.compactSpacing) {
                    if let title, let systemImage {
                        Label(title, systemImage: systemImage)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 0)

                    if showsAccessory {
                        accessory
                    }
                }
            }

            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(WorkbenchSidebarPanelStyle.cardPadding)
        .background {  RoundedRectangle(cornerRadius: WorkbenchSidebarPanelStyle.cardCornerRadius, style: .continuous)
            .fill(.ultraThinMaterial)
        }
        .contentShape(.rect(cornerRadius: WorkbenchSidebarPanelStyle.cardCornerRadius, style: .continuous))

    }
}

extension WorkbenchSidebarSectionCard where Accessory == EmptyView {
    init(
        title: String? = nil,
        systemImage: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
        self.accessory = EmptyView()
        self.showsAccessory = false
    }
}

extension View {
    func workbenchSidebarHeaderFieldStyle() -> some View {
        padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(minHeight: WorkbenchSidebarPanelStyle.controlHeight)
        .glassEffect(
            .regular,
            in: RoundedRectangle(
                cornerRadius: WorkbenchSidebarPanelStyle.controlCornerRadius,
                style: .continuous
            )
        )
    }

    func workbenchSidebarCardStyle(padding: CGFloat = WorkbenchSidebarPanelStyle.cardPadding) -> some View {
        self
            .padding(padding)
            .glassEffect(
                .regular,
                in: RoundedRectangle(
                    cornerRadius: WorkbenchSidebarPanelStyle.cardCornerRadius,
                    style: .continuous
                )
            )
    }
}
