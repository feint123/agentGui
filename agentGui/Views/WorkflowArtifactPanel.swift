//
//  WorkflowArtifactPanel.swift
//  agentGui
//
//  Displays all the structured artifacts produced by a workflow instance,
//  grouped by kind, with version badges and expandable content view.
//

import SwiftUI

// MARK: - WorkflowArtifactPanel

struct WorkflowArtifactPanel: View {

    let instance: WorkflowInstance

    private var artifactsByKind: [(WorkflowArtifactKind, [WorkflowArtifactRecord])] {
        let grouped = Dictionary(grouping: instance.artifacts) { record in
            record.kind
        }
        return WorkflowArtifactKind.allCases.compactMap { kind in
            guard let records = grouped[kind], !records.isEmpty else { return nil }
            let sorted = records.sorted { $0.version > $1.version }
            return (kind, sorted)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if artifactsByKind.isEmpty {
                Text("暂无工件")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                ForEach(artifactsByKind, id: \.0) { kind, records in
                    ArtifactKindSection(kind: kind, records: records)
                }
            }
        }
    }
}

// MARK: - ArtifactKindSection

private struct ArtifactKindSection: View {

    let kind: WorkflowArtifactKind
    let records: [WorkflowArtifactRecord]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: kind.icon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.blue)
                Text(kind.displayName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer()
                Text("\(records.count) 版本")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            ForEach(records) { record in
                ArtifactRow(record: record)
            }
        }
    }
}

// MARK: - ArtifactRow

private struct ArtifactRow: View {

    let record: WorkflowArtifactRecord
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    versionBadge
                    statusBadge
                    Text(record.title)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer()
                    Text("by \(record.producer)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                ScrollView {
                    Text(record.formattedContent)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 300)
                .padding(8)
                .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(.leading, 8)
    }

    private var versionBadge: some View {
        Text("v\(record.version)")
            .font(.caption2.weight(.bold).monospaced())
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(.fill.secondary, in: Capsule())
            .foregroundStyle(.secondary)
    }

    private var statusBadge: some View {
        Text(record.status.displayName)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(statusColor.opacity(0.12), in: Capsule())
            .foregroundStyle(statusColor)
    }

    private var statusColor: Color {
        switch record.status {
        case .approved:   return .green
        case .rejected:   return .red
        case .superseded: return .secondary
        case .draft:      return .orange
        }
    }
}

// MARK: - WorkflowSidebar

/// A combined sidebar panel showing workflow status, activations, messages, and artifacts.
struct WorkflowSidebar: View {

    let instance: WorkflowInstance
    @State private var selectedTab: SidebarTab = .team
    @Environment(WorkflowRuntime.self) var runtime

    enum SidebarTab: String, CaseIterable {
        case team = "团队"
        case timeline = "时间线"
        case messages = "消息"
        case artifacts = "工件"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Workflow")
                        .font(.headline)
                    Spacer()
                    WorkflowStatusBadge(status: instance.status)
                }
                Text(instance.userTask)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .padding(12)
            .background(.fill.quaternary)

            // Tab bar
            HStack(spacing: 0) {
                ForEach(SidebarTab.allCases, id: \.self) { tab in
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { selectedTab = tab }
                    } label: {
                        Text(tab.rawValue)
                            .font(.caption.weight(selectedTab == tab ? .semibold : .regular))
                            .foregroundStyle(selectedTab == tab ? .primary : .secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                    .overlay(alignment: .bottom) {
                        if selectedTab == tab {
                            Rectangle()
                                .fill(Color.accentColor)
                                .frame(height: 2)
                        }
                    }
                }
            }
            .background(.fill.tertiary)

            Divider()

            // Content
            ScrollView {
                Group {
                    switch selectedTab {
                    case .team:
                        WorkflowTeamView(instance: instance)
                    case .timeline:
                        WorkflowTimelineView(instance: instance)
                    case .messages:
                        WorkflowMessageListView(instance: instance)
                    case .artifacts:
                        WorkflowArtifactPanel(instance: instance)
                    }
                }
                .padding(12)
            }
        }
    }
}

// MARK: - WorkflowTeamView

/// Shows all participating roles in the workflow, with live status for the active one.
struct WorkflowTeamView: View {

    let instance: WorkflowInstance
    @Environment(WorkflowRuntime.self) var runtime

    var body: some View {
        let entries = roleEntries
        VStack(alignment: .leading, spacing: 6) {
            if entries.isEmpty {
                Text("暂无角色信息")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(entries, id: \.name) { entry in
                    RoleCardView(entry: entry)
                }
            }
        }
    }

    // MARK: - Role Entry

    struct RoleEntry {
        let name: String
        let displayName: String
        let activationCount: Int
        let isActive: Bool
        let currentAction: String?
        let isBlocked: Bool
    }

    private var roleEntries: [RoleEntry] {
        // Prefer live context when the runtime is running this workflow
        if let ctx = runtime.activeContext, ctx.workflowId == instance.id {
            return ctx.roles.map { role in
                let state = ctx.agentStates[role.name]
                return RoleEntry(
                    name: role.name,
                    displayName: role.displayName,
                    activationCount: state?.activationCount ?? 0,
                    isActive: runtime.activeRoleName == role.name,
                    currentAction: runtime.currentActionByRole[role.name],
                    isBlocked: state?.isBlocked ?? false
                )
            }
        }
        // Fallback: derive from persisted activation records
        var seen: [String: (displayName: String, count: Int)] = [:]
        for a in instance.sortedActivations {
            if seen[a.role] == nil { seen[a.role] = (a.roleDisplayName, 0) }
            seen[a.role]!.count += 1
        }
        return seen
            .map { k, v in RoleEntry(name: k, displayName: v.displayName, activationCount: v.count,
                                     isActive: false,
                                     currentAction: runtime.currentActionByRole[k],
                                     isBlocked: false) }
            .sorted { $0.activationCount > $1.activationCount }
    }
}

// MARK: - RoleCardView

private struct RoleCardView: View {

    let entry: WorkflowTeamView.RoleEntry

    var body: some View {
        HStack(spacing: 10) {
            avatarView
            infoStack
        }
        .padding(8)
        .background(entry.isActive ? Color.blue.opacity(0.07) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: Avatar

    private var avatarView: some View {
        ZStack {
            Circle()
                .fill(avatarColor.opacity(0.15))
                .frame(width: 32, height: 32)
            Text(avatarInitial)
                .font(.caption.weight(.bold))
                .foregroundStyle(avatarColor)
        }
        .overlay {
            if entry.isActive {
                Circle().stroke(Color.blue, lineWidth: 2)
            }
        }
    }

    // MARK: Info

    private var infoStack: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(entry.displayName)
                    .font(.caption.weight(.semibold))
                if entry.isActive {
                    ProgressView().scaleEffect(0.5).frame(width: 10, height: 10)
                }
                Spacer()
                if entry.activationCount > 0 {
                    Text("×\(entry.activationCount)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            statusLine
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        if let action = entry.currentAction, !action.isEmpty {
            Text(action)
                .font(.caption2)
                .foregroundStyle(entry.isActive ? .blue : .secondary)
                .lineLimit(2)
        } else if entry.isBlocked {
            Text("已达激活上限")
                .font(.caption2)
                .foregroundStyle(.orange)
        } else if entry.activationCount == 0 {
            Text("等待中")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: Avatar helpers

    private var avatarInitial: String { String(entry.displayName.prefix(1)) }

    private var avatarColor: Color {
        let palette: [Color] = [.blue, .green, .orange, .purple, .pink, .teal, .indigo]
        let hash = entry.name.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return palette[hash % palette.count]
    }
}

