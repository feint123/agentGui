import Foundation
import Testing
@testable import agentGui

@MainActor
struct ChatComposerSlashDebouncerTests {

    @Test func appliesOnlyLatestScheduledTextAfterDebounce() async throws {
        var debouncer = ChatComposerSlashDebouncer(debounceNanoseconds: 5_000_000)
        let recorder = AppliedTextRecorder()

        debouncer.schedule(text: "/p") { text in
            recorder.values.append(text)
        }
        debouncer.schedule(text: "/pl") { text in
            recorder.values.append(text)
        }

        try await Task.sleep(nanoseconds: 30_000_000)

        #expect(recorder.values == ["/pl"])
    }

    @Test func cancelPreventsPendingApply() async throws {
        var debouncer = ChatComposerSlashDebouncer(debounceNanoseconds: 5_000_000)
        let recorder = AppliedTextRecorder()

        debouncer.schedule(text: "/p") { text in
            recorder.values.append(text)
        }
        debouncer.cancel()

        try await Task.sleep(nanoseconds: 30_000_000)

        #expect(recorder.values.isEmpty)
    }
}

@MainActor
private final class AppliedTextRecorder {
    var values: [String] = []
}
