import Foundation
import Testing
@testable import agentGui

@MainActor
struct BackgroundPromptComposerTests {
    @Test func composerInjectsBackgroundExecutionCapsule() {
        let composer = BackgroundPromptComposer()
        let task = BackgroundAgentTask.fixture(title: "巡检", taskPrompt: "检查仓库状态")
        task.workspacePath = "/repo"

        let rendered = composer.compose(
            task: task,
            now: Date(timeIntervalSince1970: 0)
        )

        #expect(rendered.contains("任务名称：巡检"))
        #expect(rendered.contains("工作区路径：/repo"))
        #expect(rendered.contains("禁止等待人工输入"))
        #expect(rendered.contains("检查仓库状态"))
    }
}