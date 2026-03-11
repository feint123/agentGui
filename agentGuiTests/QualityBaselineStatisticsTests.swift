import Foundation
import Testing
@testable import agentGui

struct QualityBaselineStatisticsTests {

    @Test func extractsElapsedSecondsFromXcodebuildLog() {
        let log = """
        2026-03-11 16:13:27.084 xcodebuild[87848:772632] [MT] IDETestOperationsObserverDebug: 29.641 elapsed -- Testing started completed.
        """

        let elapsed = QualityBaselineStatistics.extractElapsedSeconds(from: log)

        #expect(elapsed == 29.641)
    }

    @Test func prefersLastElapsedValueWhenLogContainsMultipleTestRuns() {
        let log = """
        [MT] IDETestOperationsObserverDebug: 2.189 elapsed -- Testing started completed.
        [MT] IDETestOperationsObserverDebug: 29.109 elapsed -- Testing started completed.
        """

        let elapsed = QualityBaselineStatistics.extractElapsedSeconds(from: log)

        #expect(elapsed == 29.109)
    }

    @Test func computesMedianAverageMinimumAndMaximum() {
        let summary = QualityBaselineStatistics.summarize(samples: [29.1, 27.9, 30.0, 28.5, 28.0])

        #expect(summary?.sampleCount == 5)
        #expect(summary?.minimum == 27.9)
        #expect(summary?.median == 28.5)
        #expect(summary?.maximum == 30.0)
        #expect(summary?.average == 28.7)
    }

    @Test func returnsNilForEmptySamples() {
        #expect(QualityBaselineStatistics.summarize(samples: []) == nil)
    }
}