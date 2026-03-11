import Foundation
import Testing
@testable import agentGui

@MainActor
struct OpenFileRefreshMonitorTests {

    @Test func replacingWatchedFileStopsPreviousObservation() {
        let recorder = RecordingOpenFileObservationFactory()
        let monitor = OpenFileRefreshMonitor(observationFactory: recorder.makeFactory())

        let firstURL = URL(fileURLWithPath: "/tmp/workspace/first.md")
        let secondURL = URL(fileURLWithPath: "/tmp/workspace/second.md")

        monitor.watch(firstURL)
        let firstObservation = try! #require(recorder.observations.first)

        monitor.watch(secondURL)

        #expect(firstObservation.stopCallCount == 1)
        #expect(recorder.startedURLs == [
            firstURL.standardizedFileURL,
            secondURL.standardizedFileURL
        ])
    }

    @Test func clearingWatchStopsActiveObservationWithoutStartingAnother() {
        let recorder = RecordingOpenFileObservationFactory()
        let monitor = OpenFileRefreshMonitor(observationFactory: recorder.makeFactory())

        let fileURL = URL(fileURLWithPath: "/tmp/workspace/file.md")

        monitor.watch(fileURL)
        let observation = try! #require(recorder.observations.first)

        monitor.watch(nil)

        #expect(observation.stopCallCount == 1)
        #expect(recorder.startedURLs == [fileURL.standardizedFileURL])
    }

    @Test func activeObservationForwardsChangeToCurrentFileOnly() async {
        let recorder = RecordingOpenFileObservationFactory()
        let monitor = OpenFileRefreshMonitor(observationFactory: recorder.makeFactory())

        let fileURL = URL(fileURLWithPath: "/tmp/workspace/file.md")
        let standardizedURL = fileURL.standardizedFileURL
        var receivedURLs: [URL] = []
        monitor.onExternalChange = { receivedURLs.append($0) }

        monitor.watch(fileURL)
        let observation = try! #require(recorder.observations.first)

        observation.emitChange(for: standardizedURL)
        await Task.yield()

        #expect(receivedURLs == [standardizedURL])
    }
}

private final class RecordingOpenFileObservationFactory {
    private(set) var startedURLs: [URL] = []
    private(set) var observations: [RecordingOpenFileObservation] = []

    func makeFactory() -> OpenFileObservationFactory {
        OpenFileObservationFactory { url, onChange in
            self.startedURLs.append(url)
            let observation = RecordingOpenFileObservation(url: url, onChange: onChange)
            self.observations.append(observation)
            return observation
        }
    }
}

private final class RecordingOpenFileObservation: OpenFileObservationSession {
    let url: URL
    private let onChange: (URL) -> Void
    private(set) var stopCallCount = 0

    init(url: URL, onChange: @escaping (URL) -> Void) {
        self.url = url
        self.onChange = onChange
    }

    func stop() {
        stopCallCount += 1
    }

    func emitChange(for url: URL) {
        onChange(url)
    }
}