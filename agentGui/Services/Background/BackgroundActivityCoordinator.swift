import Foundation
import SwiftAnthropic
import SwiftData

@MainActor
final class BackgroundActivityCoordinator {
    private let settingsProvider: () -> AppSettings
    private let registry: BackgroundTaskRegistry
    private let executionCoordinator: BackgroundTaskExecutionCoordinator
    private let observationService: BackgroundTaskObservationService
    private let serviceProvider: () -> (any AnthropicService)
    private let notificationCenter: NotificationCenter
    private var refreshObserver: NSObjectProtocol?

    init(
        settingsProvider: @escaping () -> AppSettings,
        registry: BackgroundTaskRegistry,
        executionCoordinator: BackgroundTaskExecutionCoordinator,
        observationService: BackgroundTaskObservationService,
        serviceProvider: @escaping () -> (any AnthropicService) = { AnthropicServiceFactory.service(apiKey: "", betaHeaders: nil) },
        notificationCenter: NotificationCenter = .default
    ) {
        self.settingsProvider = settingsProvider
        self.registry = registry
        self.executionCoordinator = executionCoordinator
        self.observationService = observationService
        self.serviceProvider = serviceProvider
        self.notificationCenter = notificationCenter
    }

    func bootstrap(modelContext: ModelContext) async throws {
        startObservingRefreshRequests(modelContext: modelContext)
        try await refresh(modelContext: modelContext)
    }

    func refresh(modelContext: ModelContext) async throws {
        guard settingsProvider().backgroundAgentEnabled else {
            registry.invalidateAll()
            return
        }

        try registry.refresh(modelContext: modelContext)
        let tasks = try modelContext.fetch(FetchDescriptor<BackgroundAgentTask>()).filter(\.isEnabled)

        for task in tasks {
            let identifier = BackgroundTaskRegistry.schedulerIdentifier(for: task)
            registry.scheduler(for: identifier)?.setHandler { [weak self] scheduler, completion in
                guard let self else {
                    completion(.finished)
                    return
                }
                Task { @MainActor in
                    do {
                        let run = try self.observationService.recordTriggeredRun(
                            for: task,
                            schedulerIdentifier: identifier,
                            modelContext: modelContext
                        )
                        let result = try await self.executionCoordinator.execute(
                            task: task,
                            run: run,
                            service: self.serviceProvider(),
                            modelContext: modelContext,
                            environment: BackgroundExecutionEnvironment(shouldDefer: scheduler.shouldDefer)
                        )
                        completion(result)
                    } catch {
                        completion(.deferred)
                    }
                }
            }
        }
    }

    private func startObservingRefreshRequests(modelContext: ModelContext) {
        guard refreshObserver == nil else { return }
        refreshObserver = notificationCenter.addObserver(
            forName: BackgroundTaskSchedulingNotifications.refreshRequested,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                try? await self.refresh(modelContext: modelContext)
            }
        }
    }
}