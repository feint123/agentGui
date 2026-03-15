import Foundation
import Testing
@testable import agentGui

@MainActor
struct FileEditorRequestTrackerTests {

    @Test func staleTokenBecomesInvalidAfterStartingNewRequest() {
        var tracker = FileEditorRequestTracker()
        let firstURL = URL(fileURLWithPath: "/tmp/workspace/first.md")
        let secondURL = URL(fileURLWithPath: "/tmp/workspace/second.md")

        let firstToken = tracker.beginRequest(for: firstURL)
        let secondToken = tracker.beginRequest(for: secondURL)

        #expect(!tracker.isCurrent(firstToken, for: secondURL))
        #expect(tracker.isCurrent(secondToken, for: secondURL))
    }

    @Test func invalidatingTrackerRejectsPreviouslyIssuedToken() {
        var tracker = FileEditorRequestTracker()
        let fileURL = URL(fileURLWithPath: "/tmp/workspace/file.md")

        let token = tracker.beginRequest(for: fileURL)
        tracker.invalidate()

        #expect(!tracker.isCurrent(token, for: fileURL))
    }
}