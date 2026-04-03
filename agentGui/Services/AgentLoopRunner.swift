import Foundation
import SwiftAnthropic

@MainActor
/// AgentLoop 的状态机骨架。
/// 它只负责阶段分发与生命周期边界；具体 round 级副作用由 AgentLoopRoundExecutor 承担。
struct AgentLoopRunner {
	let claudeService: ClaudeService
	let request: AgentLoopRunRequest
	let runtime: AgentLoopRuntime
	let sharedState: AgentLoopSharedStateAccess
	let emitter: AgentLoopHookEmitter
	let toolExecutionCoordinator: AgentLoopToolExecutionCoordinator
	let initialState: AgentLoopRunState

	func run(messages: inout [MessageParameter.Message]) async throws -> AgentLoopRunResult {
		var state = initialState
		// Runner 持有循环本身，Executor 负责每个阶段的具体实现，两者边界固定后主循环更容易阅读和测试。
		let roundExecutor = AgentLoopRoundExecutor(
			claudeService: claudeService,
			request: request,
			runtime: runtime,
			sharedState: sharedState,
			emitter: emitter,
			toolCoordinator: toolExecutionCoordinator
		)

		await emitter.emit(
			.didStartRun,
			state: state,
			messages: messages,
			overrides: .init(metadata: [
				"modelId": request.modelId,
				"maxRounds": request.maxRounds,
				"messageCount": messages.count
			])
		)
		try await roundExecutor.applyBootstrap(state: &state, messages: &messages)

		while state.loopCtx.shouldContinue && state.loopCtx.roundIndex < request.maxRounds {
			try Task.checkCancellation()

			let outcome = try await roundExecutor.executeStreamingRound(state: &state, messages: &messages)
			try await roundExecutor.applyPhaseOutcome(outcome: outcome, state: &state, messages: &messages)

			// Session Memory hook：每轮结束后检查阈值
			await emitter.emit(
				.willFinishRound,
				state: state,
				messages: messages,
				overrides: .init(metadata: [
					"roundIndex": state.loopCtx.roundIndex,
					"toolCallsThisRound": outcome.pendingTools.count
				])
			)

			// F-B3: AutoCompact — 若 budget 达到阈值，触发对话压缩
			if let budget = sharedState.readContextBudget(), budget.isAutoCompactReady {
				if let compactedMessages = await sharedState.runCompactionIfNeeded(messages) {
					messages = compactedMessages
				}
			}
		}

		return await roundExecutor.buildResult(state: state, messages: messages)
	}
}