import Foundation

enum BackgroundTaskQualityOfService: String, Codable, CaseIterable {
    case background
    case utility
}

struct BackgroundTaskPolicy: Codable, Equatable, Sendable {
    var baseIntervalSeconds: TimeInterval
    var toleranceSeconds: TimeInterval
    var repeats: Bool
    var qualityOfService: BackgroundTaskQualityOfService
    var allowedWeekdays: [Int]
    var allowedHourRange: ClosedRange<Int>?
    var requiresNetwork: Bool

    init(
        baseIntervalSeconds: TimeInterval = 21_600,
        toleranceSeconds: TimeInterval = 3_600,
        repeats: Bool = true,
        qualityOfService: BackgroundTaskQualityOfService = .utility,
        allowedWeekdays: [Int] = [],
        allowedHourRange: ClosedRange<Int>? = nil,
        requiresNetwork: Bool = false
    ) {
        self.baseIntervalSeconds = baseIntervalSeconds
        self.toleranceSeconds = toleranceSeconds
        self.repeats = repeats
        self.qualityOfService = qualityOfService
        self.allowedWeekdays = allowedWeekdays
        self.allowedHourRange = allowedHourRange
        self.requiresNetwork = requiresNetwork
    }

    var sanitizedForScheduling: BackgroundTaskPolicy {
        var sanitized = self
        sanitized.baseIntervalSeconds = max(baseIntervalSeconds, 1)
        sanitized.toleranceSeconds = sanitizedToleranceSeconds
        sanitized.allowedWeekdays = sanitizedAllowedWeekdays
        sanitized.allowedHourRange = sanitizedAllowedHourRange
        return sanitized
    }

    var sanitizedToleranceSeconds: TimeInterval {
        let interval = max(baseIntervalSeconds, 1)
        let upperBound = max(interval.nextDown, 0)
        return min(max(toleranceSeconds, 0), upperBound)
    }

    var sanitizedAllowedWeekdays: [Int] {
        Array(Set(allowedWeekdays.filter { (1...7).contains($0) })).sorted()
    }

    var sanitizedAllowedHourRange: ClosedRange<Int>? {
        guard let allowedHourRange else { return nil }
        let lowerBound = min(max(allowedHourRange.lowerBound, 0), 23)
        let upperBound = min(max(allowedHourRange.upperBound, 0), 23)
        return min(lowerBound, upperBound)...max(lowerBound, upperBound)
    }
}