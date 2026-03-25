import SwiftUI

struct CommandPaletteView: View {
    @Environment(CommandPaletteViewModel.self) private var viewModel

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()
                .overlay(.quaternary)

            Group {
                if viewModel.results.isEmpty {
                    emptyState
                } else {
                    resultList
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
                .overlay(.quaternary)

            footer
        }
        .frame(minWidth: 720, minHeight: 520)
        .background(panelBackground)
        .clipShape(.rect(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.10), lineWidth: 0.5)
        }
        .onMoveCommand { direction in
            switch direction {
            case .down:
                viewModel.moveSelection(downward: true)
            case .up:
                viewModel.moveSelection(downward: false)
            default:
                break
            }
        }
        .onExitCommand {
            if viewModel.query.isEmpty {
                viewModel.markDismissed()
            } else {
                viewModel.query = ""
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.secondary)

                TextField("输入命令、会话、工作区或文件", text: queryBinding)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .onSubmit(executeSelectedItem)

                if !viewModel.query.isEmpty {
                    Button {
                        viewModel.query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }

                Text(viewModel.resultCountDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(searchFieldBackground)

            if let selectedItem = viewModel.selectedItem {
                HStack(spacing: 8) {
                    Text(selectedItem.group.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)

                    if let subtitle = selectedItem.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 14)
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "没有匹配结果",
            systemImage: "magnifyingglass",
            description: Text("尝试缩短关键字，或先打开工作区后再搜索文件。")
        )
    }

    private var resultList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(viewModel.sections) { section in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(section.group.title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)
                                .padding(.horizontal, 4)

                            ForEach(section.items) { item in
                                resultRow(for: item)
                                    .id(item.id)
                            }
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
            }
            .scrollIndicators(.hidden)
            .onChange(of: viewModel.selectedItemID) { _, selectedItemID in
                guard let selectedItemID else { return }
                withAnimation(.snappy(duration: 0.16, extraBounce: 0)) {
                    proxy.scrollTo(selectedItemID, anchor: .center)
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                if let selectedItem = viewModel.selectedItem {
                    Text(selectedItem.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)

                    Text(selectedItem.subtitle ?? selectedItem.group.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("暂无选择")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            HStack(spacing: 8) {
                keyboardHint("↑↓", title: "选择")
                keyboardHint("↵", title: "打开")
                keyboardHint("esc", title: viewModel.query.isEmpty ? "关闭" : "清空")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private var queryBinding: Binding<String> {
        Binding(
            get: { viewModel.query },
            set: { viewModel.query = $0 }
        )
    }

    @ViewBuilder
    private var searchFieldBackground: some View {
        if #available(macOS 26, *) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.clear)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.regularMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(.quaternary)
                }
        }
    }

    @ViewBuilder
    private var panelBackground: some View {
        if #available(macOS 26, *) {
            Rectangle()
                .fill(.thinMaterial)
        } else {
            Rectangle()
                .fill(.regularMaterial)
        }
    }

    private func resultRow(for item: CommandPaletteItem) -> some View {
        let isSelected = item.id == viewModel.selectedItem?.id

        return Button {
            Task { @MainActor in
                _ = await viewModel.execute(item)
            }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(iconBackground(isSelected: isSelected, isEnabled: item.isEnabled))
                    .frame(width: 30, height: 30)
                    .overlay {
                        Image(systemName: item.systemImage)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(item.isEnabled ? Color.accentColor : .secondary)
                    }

                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(item.isEnabled ? Color.primary : .secondary)

                    if let subtitle = item.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    if let disabledReason = item.disabledReason, item.isEnabled == false {
                        Text(disabledReason)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 12)

                VStack(alignment: .trailing, spacing: 6) {
                    if let accessoryTitle = item.accessoryTitle, !accessoryTitle.isEmpty {
                        Text(accessoryTitle)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.regularMaterial, in: Capsule())
                    }

                    if isSelected {
                        Image(systemName: "return")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(rowBackground(isSelected: isSelected))
        }
        .buttonStyle(.plain)
        .disabled(!item.isEnabled)
        .accessibilityIdentifier(item.id)
    }

    private func rowBackground(isSelected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(isSelected ? Color.accentColor.opacity(0.16) : Color.clear)
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor.opacity(0.28) : Color.secondary.opacity(0.08))
            }
    }

    private func iconBackground(isSelected: Bool, isEnabled: Bool) -> some ShapeStyle {
        if isSelected {
            return AnyShapeStyle(Color.accentColor.opacity(0.12))
        }

        return AnyShapeStyle(isEnabled ? Color.secondary.opacity(0.10) : Color.secondary.opacity(0.06))
    }

    private func keyboardHint(_ key: String, title: String) -> some View {
        HStack(spacing: 6) {
            Text(key)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func executeSelectedItem() {
        Task { @MainActor in
            _ = await viewModel.executeSelected()
        }
    }
}