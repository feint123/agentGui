import Foundation

struct StoryMemorySubagentPromptBuilder {
    func buildTask(from request: StoryMemoryDelegationRequest) -> String {
        var lines: [String] = [
            "你是创作记忆管理员，只处理项目记忆检索、canon 写入审查和连续性核对。",
            "项目 ID：\(request.projectId)",
            "项目标题：\(request.projectTitle)",
            "任务类型：\(request.taskType.rawValue)",
            "用户请求：\(request.userRequest)",
            "返回结构必须区分 facts、inferences、risks。"
        ]

        if let candidateText = request.candidateText, !candidateText.isEmpty {
            lines.append("候选写入内容：\(candidateText)")
        }

        return lines.joined(separator: "\n")
    }
}