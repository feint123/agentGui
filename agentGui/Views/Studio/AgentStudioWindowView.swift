import SwiftData
import SwiftUI

struct AgentStudioWindowView: View {
    @Environment(ClaudeService.self) private var claudeService
    @Environment(\.scenePhase) private var scenePhase

    @Query(sort: \Session.updatedAt, order: .reverse)
    private var sessions: [Session]

    @Query
    private var allToolCalls: [ToolCall]

    @State private var builder = AgentStudioProjectionBuilder()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            AgentStudioView(
                projection: builder.projection,
                isScenePaused: shouldPauseScene
            )
            .frame(minWidth: 720, minHeight: 420)

            footer
        }
        .padding(20)
        .frame(minWidth: 760, minHeight: 560)
        .accessibilityIdentifier("window.agentStudio")
        .task(id: projectionSignature) {
            rebuildProjection()
        }
        .onAppear {
            rebuildProjection()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Agent 工作室")
                .font(.title2.bold())
            Text(headerSubtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack {
            Text("活跃角色 \(builder.projection.characters.count)/8")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            Text(shouldPauseScene ? "场景已暂停" : "场景运行中")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var headerSubtitle: String {
        if builder.projection.characters.isEmpty {
            return "当前没有正在展示的活跃会话。"
        }
        return "像素场景会根据会话执行状态实时刷新。"
    }

    private var shouldPauseScene: Bool {
        scenePhase != .active || builder.projection.characters.isEmpty
    }

    private var activeToolCalls: [ToolCall] {
        allToolCalls
            .filter { $0.status == .inProgress && !$0.isPermissionRequest }
            .sorted { ($0.startTime ?? .distantPast) < ($1.startTime ?? .distantPast) }
    }

    private var projectionSignature: String {
        let sessionPart = sessions
            .map { "\($0.sessionId)|\($0.title)|\($0.updatedAt.timeIntervalSinceReferenceDate)|\($0.defaultExecutionProviderID)" }
            .joined(separator: "#")

        let projectionPart = claudeService.executionProjectionStore.projections.values
            .sorted { $0.sessionID < $1.sessionID }
            .map {
                let phase = $0.currentPhase?.label ?? "nil"
                let provider = $0.activeProviderID?.rawValue ?? "nil"
                let runningJobID = $0.runningJobID?.uuidString ?? "nil"
                return "\($0.sessionID)|\(runningJobID)|\($0.queuedCount)|\($0.isRunning)|\(provider)|\(phase)"
            }
            .joined(separator: "#")

        let toolPart = activeToolCalls
            .map {
                let sessionID = $0.terminalSessionID ?? ""
                let startedAt = ($0.startTime ?? .distantPast).timeIntervalSinceReferenceDate
                return "\($0.id.uuidString)|\(sessionID)|\($0.agentStudioToolName)|\(startedAt)"
            }
            .joined(separator: "#")

        return [sessionPart, projectionPart, toolPart].joined(separator: "||")
    }

    private func rebuildProjection() {
        builder.rebuild(
            sessions: sessions,
            execProjections: claudeService.executionProjectionStore.projections,
            currentToolNames: claudeService.agentStudioCurrentToolNames(toolCalls: activeToolCalls)
        )
    }
}