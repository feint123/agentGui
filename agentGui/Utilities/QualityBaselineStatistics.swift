import Foundation

struct QualityBaselineSummary: Equatable {
    let sampleCount: Int
    let minimum: Double
    let median: Double
    let maximum: Double
    let average: Double
}

enum QualityBaselineStatistics {
    static func extractElapsedSeconds(from log: String) -> Double? {
        let pattern = #"IDETestOperationsObserverDebug:\s*([0-9]+(?:\.[0-9]+)?) elapsed -- Testing started completed"#

        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }

        let range = NSRange(log.startIndex..<log.endIndex, in: log)
        let matches = regex.matches(in: log, range: range)
        guard let match = matches.last,
              let valueRange = Range(match.range(at: 1), in: log) else {
            return nil
        }

        return Double(log[valueRange])
    }

    static func summarize(samples: [Double]) -> QualityBaselineSummary? {
        let sorted = samples.sorted()
        guard !sorted.isEmpty else { return nil }

        let median: Double
        if sorted.count.isMultiple(of: 2) {
            let upperIndex = sorted.count / 2
            median = rounded((sorted[upperIndex - 1] + sorted[upperIndex]) / 2)
        } else {
            median = rounded(sorted[sorted.count / 2])
        }

        let average = rounded(sorted.reduce(0, +) / Double(sorted.count))

        return QualityBaselineSummary(
            sampleCount: sorted.count,
            minimum: rounded(sorted.first ?? 0),
            median: median,
            maximum: rounded(sorted.last ?? 0),
            average: average
        )
    }

    private static func rounded(_ value: Double) -> Double {
        (value * 1000).rounded() / 1000
    }
}