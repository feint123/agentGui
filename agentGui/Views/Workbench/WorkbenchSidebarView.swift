import SwiftUI
import SwiftData

struct WorkbenchSidebarView: View {
    @Environment(WorkbenchState.self) private var workbenchState
    @Environment(WorkspaceState.self) private var workspaceState
    @Namespace private var navigationGlassNamespace

    var body: some View {
        VStack(spacing: 0) {
            navigationBar
            currentPanelContainer
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .accessibilityIdentifier("workbench.sidebar")
    }

    private var navigationBar: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 6) {
                ForEach(WorkbenchNavigationItem.allCases, id: \.self) { item in
                    WorkbenchSidebarNavigationButton(
                        item: item,
                        isSelected: workbenchState.selectedItem == item,
                        namespace: navigationGlassNamespace,
                        action: {
                            select(item)
                        }
                    )
                }
            }
            .padding(4)
            .frame(maxWidth: .infinity)
            .glassEffect(.regular, in: Capsule())
            .shadow(color: .black.opacity(0.12), radius: 16, y: 8)
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    private var currentPanelContainer: some View {
        ZStack {
            ForEach(WorkbenchNavigationItem.allCases, id: \.self) { item in
                panelView(for: item)
                    .opacity(workbenchState.selectedItem == item ? 1 : 0)
                    .allowsHitTesting(workbenchState.selectedItem == item)
                    .accessibilityHidden(workbenchState.selectedItem != item)
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }
        }
        .animation(.snappy(duration: 0.22, extraBounce: 0.02), value: workbenchState.selectedItem)
    }

    @ViewBuilder
    private func panelView(for item: WorkbenchNavigationItem) -> some View {
        switch item {
        case .sessions:
            SessionListView { session in
                workspaceState.selectedSession = session
            }
            .accessibilityIdentifier("panel.sessions")
        case .workspace:
            WorkspacePanelView()
        case .git:
            WorkbenchGitPanelView()
                .accessibilityIdentifier("panel.git")
        case .lsp:
            WorkbenchLSPPanelView()
                .accessibilityIdentifier("panel.lsp")
        case .skills:
            SkillsView()
                .accessibilityIdentifier("panel.skills")
        case .diagnostics:
            ReliabilityCenterView()
                .accessibilityIdentifier("panel.diagnostics")
        }
    }

    private func select(_ item: WorkbenchNavigationItem) {
        guard workbenchState.selectedItem != item else { return }

        withAnimation(.snappy(duration: 0.24, extraBounce: 0.03)) {
            workbenchState.selectedItem = item
        }
    }
}

private struct WorkbenchSidebarNavigationButton: View {
    let item: WorkbenchNavigationItem
    let isSelected: Bool
    let namespace: Namespace.ID
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: item.systemImage)
                .font(.system(size: 14, weight: isSelected ? .semibold : .medium))
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .contentShape(Capsule())
                .background(buttonBackground)
                .overlay {
                    if isSelected {
                        Capsule()
                            .stroke(Color.white.opacity(0.14), lineWidth: 0.8)
                    }
                }
        }
        .buttonStyle(.plain)
        .foregroundStyle(foregroundStyle)
        .help(item.title)
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier(item.accessibilityIdentifier)
        .scaleEffect(isHovered && !isSelected ? 1.03 : 1)
        .animation(.easeInOut(duration: 0.12), value: isHovered)
        .onHover { isHovered = $0 }
    }

    private var foregroundStyle: some ShapeStyle {
        isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary)
    }

    @ViewBuilder
    private var buttonBackground: some View {
        if isSelected {
            Capsule()
                .fill(Color.accentColor.opacity(0.20))
                .matchedGeometryEffect(id: "workbench.sidebar.selection", in: namespace)
        } else if isHovered {
            Capsule()
                .fill(Color.primary.opacity(0.06))
        }
    }
}