import SwiftUI

struct CommandPaletteView: View {
    @Environment(CommandPaletteViewModel.self) private var viewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()
                .overlay(.quaternary)

            if viewModel.results.isEmpty {
                emptyState
            } else {
                resultList
            }

            Divider()
                .overlay(.quaternary)

            footer
        }
        .frame(minWidth: 720, minHeight: 520)
        .background(background)
        .navigationTitle("命令面板")
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
                dismiss()
            } else {
                viewModel.query = ""
            }
        }
        .onChange(of: viewModel.isPresented) { _, isPresented in
            if !isPresented {
                dismiss()
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                Label("命令面板", systemImage: "command.circle")
                    .font(.headline)
                    .foregroundStyle(.primary)

                Spacer()

                Text(viewModel.resultCountDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.regularMaterial, in: Capsule())
            }

            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.secondary)

                TextField("输入命令、会话、工作区或文件", text: queryBinding)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .onSubmit {
                        executeSelectedItem()
                    }

                if !viewModel.query.isEmpty {
                    Button {
                        viewModel.query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(.quaternary)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "没有匹配结果",
            systemImage: "magnifyingglass",
            description: Text("尝试缩短关键字，或先打开工作区后再搜索文件。")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var resultList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18, pinnedViews: [.sectionHeaders]) {
                    ForEach(viewModel.sections) { section in
                        Section {
                            VStack(spacing: 6) {
                                ForEach(section.items) { item in
                                    button(for: item)
                                        .id(item.id)
                                }
                            }
                        } header: {
                            sectionHeader(section.group.title)
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
        .background(.ultraThinMaterial)
    }

    private var queryBinding: Binding<String> {
        Binding(
            get: { viewModel.query },
            set: { viewModel.query = $0 }
        )
    }

    private func button(for item: CommandPaletteItem) -> some View {
        let isSelected = item.id == viewModel.selectedItem?.id

        return Button {
            Task { @MainActor in
                _ = await viewModel.execute(item)
                if !viewModel.isPresented {
                    dismiss()
                }
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
            .background(backgroundShape(isSelected: isSelected))
        }
        .buttonStyle(.plain)
        .disabled(!item.isEnabled)
        .accessibilityIdentifier(item.id)
    }

    @ViewBuilder
    private func backgroundShape(isSelected: Bool) -> some View {
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

    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            Spacer()
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 8)
        .background(.thinMaterial)
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

    private var background: some View {
        LinearGradient(
            colors: [
                Color(nsColor: .windowBackgroundColor),
                Color(nsColor: .underPageBackgroundColor)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .overlay {
            Rectangle()
                .fill(.regularMaterial)
                .opacity(0.62)
        }
    }

    private func executeSelectedItem() {
        Task { @MainActor in
            _ = await viewModel.executeSelected()
            if !viewModel.isPresented {
                dismiss()
            }
        }
    }
}