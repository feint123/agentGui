import Foundation
import Testing
@testable import agentGui

@MainActor
struct LaunchReadinessEvaluatorTests {

    @Test func evaluateMarksAppAsBlockedWhenAPIKeyIsMissing() {
        let settings = AppSettings.testFixture(apiKey: "")

        let readiness = LaunchReadinessEvaluator.evaluate(settings: settings)

        #expect(readiness.isReadyForFirstMessage == false)
        #expect(readiness.primaryBlockingReason == .missingAPIKey)
        #expect(readiness.items.contains(where: { $0.kind == .apiKey && !$0.isSatisfied }))
    }

    @Test func evaluateMarksWorkingDirectoryAsRecommendedWhenAPIKeyExists() {
        let settings = AppSettings.testFixture(apiKey: "sk-ant-demo")
        settings.workingDirectory = ""

        let readiness = LaunchReadinessEvaluator.evaluate(settings: settings)

        #expect(readiness.isReadyForFirstMessage == true)
        #expect(readiness.primaryBlockingReason == nil)
        #expect(readiness.items.contains(where: { $0.kind == .workingDirectory && !$0.isSatisfied }))
    }

    @Test func evaluateReturnsReadyWhenAPIKeyAndWorkingDirectoryExist() {
        let settings = AppSettings.testFixture(apiKey: "sk-ant-demo")
        settings.workingDirectory = "/tmp/project"

        let readiness = LaunchReadinessEvaluator.evaluate(settings: settings)

        #expect(readiness.isReadyForFirstMessage == true)
        #expect(readiness.items.filter { !$0.isSatisfied }.isEmpty)
    }
}