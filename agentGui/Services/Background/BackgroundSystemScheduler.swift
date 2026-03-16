import AppKit
import Foundation

enum BackgroundSystemSchedulerResult: Equatable {
    case finished
    case deferred
}

typealias BackgroundSystemSchedulerCompletion = @MainActor (BackgroundSystemSchedulerResult) -> Void
typealias BackgroundSystemSchedulerHandler = @MainActor (_ scheduler: any BackgroundSystemScheduler, _ completion: @escaping BackgroundSystemSchedulerCompletion) -> Void

@MainActor
protocol BackgroundSystemScheduler: AnyObject {
    var identifier: String { get }
    var interval: TimeInterval { get set }
    var tolerance: TimeInterval { get set }
    var repeats: Bool { get set }
    var qualityOfService: BackgroundTaskQualityOfService { get set }
    var shouldDefer: Bool { get }

    func setHandler(_ handler: @escaping BackgroundSystemSchedulerHandler)
    func invalidate()
}

struct BackgroundSystemSchedule: Equatable, Sendable {
    var interval: TimeInterval
    var tolerance: TimeInterval
    var repeats: Bool
    var qualityOfService: BackgroundTaskQualityOfService
}

@MainActor
final class NSBackgroundSystemSchedulerAdapter: BackgroundSystemScheduler {
    let identifier: String

    var interval: TimeInterval {
        get { scheduler.interval }
        set { scheduler.interval = newValue }
    }

    var tolerance: TimeInterval {
        get { scheduler.tolerance }
        set { scheduler.tolerance = newValue }
    }

    var repeats: Bool {
        get { scheduler.repeats }
        set { scheduler.repeats = newValue }
    }

    var qualityOfService: BackgroundTaskQualityOfService = .utility

    var shouldDefer: Bool {
        scheduler.shouldDefer
    }

    private let scheduler: NSBackgroundActivityScheduler
    private var handler: BackgroundSystemSchedulerHandler?

    init(identifier: String) {
        self.identifier = identifier
        self.scheduler = NSBackgroundActivityScheduler(identifier: identifier)
    }

    func setHandler(_ handler: @escaping BackgroundSystemSchedulerHandler) {
        self.handler = handler
        scheduler.qualityOfService = qualityOfService.nsQualityOfService
        scheduler.schedule { [weak self] completion in
            guard let self else {
                completion(.finished)
                return
            }
            Task { @MainActor in
                self.handler?(self) { result in
                    completion(result.nsResult)
                }
            }
        }
    }

    func invalidate() {
        scheduler.invalidate()
    }
}

private extension BackgroundTaskQualityOfService {
    var nsQualityOfService: QualityOfService {
        switch self {
        case .background:
            return .background
        case .utility:
            return .utility
        }
    }
}

private extension BackgroundSystemSchedulerResult {
    var nsResult: NSBackgroundActivityScheduler.Result {
        switch self {
        case .finished:
            return .finished
        case .deferred:
            return .deferred
        }
    }
}