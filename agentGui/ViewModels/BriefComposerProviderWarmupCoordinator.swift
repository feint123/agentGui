import Foundation
import SwiftData
import Observation

@Observable
@MainActor
final class BriefComposerProviderWarmupCoordinator {
    enum WarmupState: Equatable {
        case idle
        case warming
        case ready(modes: [ExecutionOptionItem], modelOptions: [ExecutionOptionItem])
        case failed
    }

    private var states: [ExecutionProviderReference: WarmupState] = [:]

    // MARK: - 查询

    func warmupState(for provider: ExecutionProviderReference) -> WarmupState {
        states[provider] ?? .idle
    }

    var isWarmingAny: Bool {
        states.values.contains(where: { $0 == .warming })
    }

    func modelOptions(for provider: ExecutionProviderReference) -> [ExecutionOptionItem] {
        if case .ready(_, let models) = states[provider] { return models }
        return fallbackModelOptions(for: provider)
    }

    func modeOptions(for provider: ExecutionProviderReference) -> [ExecutionOptionItem] {
        if case .ready(let modes, _) = states[provider] { return modes }
        return []
    }

    // MARK: - 状态写入（由 warmup 方法和测试调用）

    func markWarming(_ provider: ExecutionProviderReference) {
        states[provider] = .warming
    }

    func markReady(
        _ provider: ExecutionProviderReference,
        modes: [ExecutionOptionItem],
        modelOptions: [ExecutionOptionItem]
    ) {
        states[provider] = .ready(modes: modes, modelOptions: modelOptions)
    }

    func markFailed(_ provider: ExecutionProviderReference) {
        states[provider] = .failed
    }

    // MARK: - 真实 warm-up 入口（在 View 的 .task 中调用）

    /// 对单个 ACP provider 触发 warm-up，超时 8 秒后 markFailed。
    func warmup(
        provider: ExecutionProviderReference,
        claudeService: ClaudeService,
        sourceSession: Session?,
        modelContext: ModelContext
    ) async {
        guard states[provider] == nil || states[provider] == .idle else { return }
        markWarming(provider)
        do {
            let result = try await withThrowingTaskGroup(of: WarmupResult?.self) { group in
                group.addTask {
                    try await Task.sleep(for: .seconds(8))
                    throw CancellationError()
                }
                group.addTask { @MainActor in
                    let probeSession: Session
                    let isTemporary: Bool
                    if let existing = sourceSession {
                        probeSession = existing
                        isTemporary = false
                    } else {
                        probeSession = Session(title: "__warmup_probe__", kind: .local)
                        modelContext.insert(probeSession)
                        isTemporary = true
                    }
                    defer {
                        if isTemporary {
                            modelContext.delete(probeSession)
                        }
                    }
                    await claudeService.handleExecutionProviderSelectionChange(
                        session: probeSession,
                        selectedProviderReference: provider,
                        modelContext: modelContext,
                        trigger: .sessionBootstrap
                    )
                    // 通过 registry 读取配置快照
                    let registry = claudeService.executionProviderRegistry
                    let acpProvider = registry?.providerIfAvailable(for: provider) as? ACPRemoteSessionConfigurationControlling
                    let snapshot = acpProvider?.remoteSessionConfiguration(localSessionID: probeSession.sessionId)
                    let modes = snapshot?.modes?.availableModes.map {
                        ExecutionOptionItem(id: $0.id, title: $0.name)
                    } ?? []
                    let models: [ExecutionOptionItem]
                    if let snapshot, !snapshot.configOptions.isEmpty {
                        models = snapshot.modelConfigOption?.options.flattenedOptions.map {
                            ExecutionOptionItem(id: $0.value, title: $0.name)
                        } ?? self.fallbackModelOptions(for: provider)
                    } else {
                        models = self.fallbackModelOptions(for: provider)
                    }
                    return WarmupResult(modes: modes, modelOptions: models)
                }
                guard let firstResult = try await group.next() else {
                    group.cancelAll()
                    return WarmupResult?.none
                }
                group.cancelAll()
                return firstResult
            }
            if let result = result {
                markReady(provider, modes: result.modes, modelOptions: result.modelOptions)
            } else {
                markFailed(provider)
            }
        } catch {
            markFailed(provider)
        }
    }

    // MARK: - Private

    private struct WarmupResult {
        let modes: [ExecutionOptionItem]
        let modelOptions: [ExecutionOptionItem]
    }

    private func fallbackModelOptions(for provider: ExecutionProviderReference) -> [ExecutionOptionItem] {
        if provider == LegacyExternalACPProviderKey.githubCopilotCLI.compatibilityReference {
            return GitHubCopilotCLIConfiguration.curatedModelOptions
        }
        return []
    }
}
