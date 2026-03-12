//
//  TodoListView.swift
//  agentGui
//

import SwiftUI

struct TodoListView: View {
    let items: [TodoItem]
    let maxHeight: CGFloat?
    let showsScrollIndicators: Bool

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(items) { item in
                    TodoRowContentView(item: item)
                        .padding(.horizontal, 12)
                }
            }
        }
        .scrollIndicators(showsScrollIndicators ? .visible : .hidden)
        .frame(maxHeight: maxHeight)
    }
}

struct TodoRowContentView: View {
    let item: TodoItem

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: item.status.icon)
                .font(.system(size: 11))
                .foregroundStyle(statusColor)
                .frame(width: 14, alignment: .center)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 1) {
                TodoTitleTextView(item: item)
                if let notes = item.notes, !notes.isEmpty {
                    Text(notes)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(rowBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("chat.todoCard.row.\(item.id)")
    }

    private var statusColor: Color {
        switch item.status {
        case .pending:    return .secondary
        case .inProgress: return .accentColor
        case .done:       return .green
        case .cancelled:  return .secondary
        }
    }

    @ViewBuilder
    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(backgroundFillColor)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(borderColor, lineWidth: item.status == .inProgress ? 1 : 0)
            )
    }

    private var backgroundFillColor: Color {
        switch item.status {
        case .inProgress:
            return Color.accentColor.opacity(0.06)
        case .done:
            return Color.primary.opacity(0.04)
        case .pending, .cancelled:
            return Color.primary.opacity(0.03)
        }
    }

    private var borderColor: Color {
        item.status == .inProgress ? Color.accentColor.opacity(0.14) : .clear
    }
}

private struct TodoTitleTextView: View {
    let item: TodoItem

    var body: some View {
        if item.status == .inProgress {
            TimelineView(.animation) { context in
                let progress = context.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: 1.9) / 1.9

                baseText
                    .overlay {
                        GeometryReader { proxy in
                            let width = max(proxy.size.width, 1)

                            LinearGradient(
                                colors: [
                                    .clear,
                                    Color.white.opacity(0.12),
                                    Color.white.opacity(0.92),
                                    Color.white.opacity(0.16),
                                    .clear
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                            .frame(width: max(52, width * 0.4))
                            .offset(x: -width * 0.5 + (width * 1.5 * progress))
                        }
                        .mask(baseText)
                        .allowsHitTesting(false)
                    }
            }
            .accessibilityIdentifier("chat.todoCard.inProgressGlow.\(item.id)")
        } else {
            baseText
        }
    }

    private var baseText: some View {
        Text(item.title)
            .font(.caption)
            .foregroundStyle(titleForegroundStyle)
            .strikethrough(item.status == .done || item.status == .cancelled)
            .lineLimit(3)
    }

    private var titleForegroundStyle: AnyShapeStyle {
        switch item.status {
        case .done:
            return AnyShapeStyle(Color.secondary.opacity(0.7))
        case .inProgress:
            return AnyShapeStyle(Color.primary.opacity(0.6))
        case .pending:
            return AnyShapeStyle(Color.primary)
        case .cancelled:
            return AnyShapeStyle(Color.secondary)
        }
    }
}

// MARK: - Preview

#Preview("Todo List") {
    TodoListView(
        items: [
            TodoItem(
                id: "todo-pending",
                title: "梳理 AgentLoop finalization 的 verify 路径",
                status: .pending,
                notes: "确认旧的 requiresExecution 逻辑已经完全移除。"
            ),
            TodoItem(
                id: "todo-progress",
                title: "补充 TodoListView 的预览和滚动效果",
                status: .inProgress,
                notes: "需要覆盖进行中、完成和取消等状态。"
            ),
            TodoItem(
                id: "todo-done",
                title: "收敛 AgentLoopRunner 的主循环骨架",
                status: .done,
                notes: "已抽取到 AgentLoopRoundExecutor。"
            ),
            TodoItem(
                id: "todo-cancelled",
                title: "保留旧 execution guard 兜底",
                status: .cancelled,
                notes: "verify 机制成熟后不再需要。"
            )
        ],
        maxHeight: 220,
        showsScrollIndicators: true
    )
    .padding()
    .frame(width: 360)
}

#Preview("Todo Row") {
    TodoRowContentView(
        item: TodoItem(
            id: "todo-row-preview",
            title: "修复 SwiftUI 列表行的视觉状态",
            status: .inProgress,
            notes: "观察高亮动画和边框是否符合预期。"
        )
    )
    .padding()
    .frame(width: 360)
}

