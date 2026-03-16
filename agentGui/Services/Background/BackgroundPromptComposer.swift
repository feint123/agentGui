import Foundation

@MainActor
struct BackgroundPromptComposer {
    func compose(task: BackgroundAgentTask, now: Date) -> String {
        let timestamp = ISO8601DateFormatter().string(from: now)
        let workspaceLine = "工作区路径：\(task.workspacePath ?? "未设置")"

        return [
            "你正在执行一个后台定时任务。",
            "任务名称：\(task.title)",
            "触发时间：\(timestamp)",
            workspaceLine,
            "执行约束：禁止等待人工输入；若信息不足，请给出保守结论并收敛输出。",
            "用户提示词：",
            task.taskPrompt
        ].joined(separator: "\n")
    }
}