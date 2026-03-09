import Foundation
import Testing
@testable import agentGui

struct BashCommandClassifierTests {

    @Test func classifiesDevServerAsBackgroundCandidate() async throws {
        let result = BashCommandClassifier().classify(
            command: "npm run dev",
            goalHint: "启动服务并继续编码"
        )

        #expect(result.classification == .background)
        #expect(result.executionMode == .background)
        #expect(result.confidence > 0.5)
    }

    @Test func classifiesCreateCommandAsInteractive() async throws {
        let result = BashCommandClassifier().classify(
            command: "npx create-next-app demo",
            goalHint: "初始化项目"
        )

        #expect(result.classification == .interactive)
        #expect(result.executionMode == .interactive)
    }

    @Test func classifiesGitCommitWithoutMessageAsInteractive() async throws {
        let result = BashCommandClassifier().classify(
            command: "git commit",
            goalHint: nil
        )

        #expect(result.classification == .interactive)
    }

    @Test func classifiesPythonReplAsInteractive() async throws {
        let result = BashCommandClassifier().classify(
            command: "python",
            goalHint: "进入解释器检查数据"
        )

        #expect(result.classification == .interactive)
    }

    @Test func classifiesXcodebuildTestAsForeground() async throws {
        let result = BashCommandClassifier().classify(
            command: "xcodebuild test -scheme agentGui",
            goalHint: "运行测试并等待结果"
        )

        #expect(result.classification == .foreground)
        #expect(result.executionMode == .foreground)
    }

    @Test func keepsUnknownCommandsConservative() async throws {
        let result = BashCommandClassifier().classify(
            command: "custom-tool --flag",
            goalHint: nil
        )

        #expect(result.classification == .unknown)
        #expect(result.executionMode == .foreground)
        #expect(result.confidence < 0.5)
    }
}