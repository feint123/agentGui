import Foundation

enum TerminalCommandClassification: String, Codable, Equatable, Sendable {
    case foreground
    case background
    case interactive
    case interactiveBackgroundBootstrap
    case monitorOnly
    case unknown
}

struct BashCommandClassificationResult: Equatable, Sendable {
    var classification: TerminalCommandClassification
    var executionMode: TerminalExecutionMode
    var confidence: Double
    var reasons: [String]
}

struct BashCommandClassifier {

    func classify(command: String, goalHint: String?) -> BashCommandClassificationResult {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.lowercased()
        let hint = goalHint?.lowercased() ?? ""

        if isInteractiveCommand(normalized) {
            return BashCommandClassificationResult(
                classification: .interactive,
                executionMode: .interactive,
                confidence: 0.9,
                reasons: ["matched interactive command pattern"]
            )
        }

        if isBackgroundCandidate(normalized, goalHint: hint) {
            return BashCommandClassificationResult(
                classification: .background,
                executionMode: .background,
                confidence: 0.8,
                reasons: ["matched long-running server or watch pattern"]
            )
        }

        if isForegroundCommand(normalized, goalHint: hint) {
            return BashCommandClassificationResult(
                classification: .foreground,
                executionMode: .foreground,
                confidence: 0.75,
                reasons: ["matched foreground build or test pattern"]
            )
        }

        return BashCommandClassificationResult(
            classification: .unknown,
            executionMode: .foreground,
            confidence: 0.2,
            reasons: ["no known command pattern matched"]
        )
    }

    private func isInteractiveCommand(_ command: String) -> Bool {
        let exactCommands = ["python", "python3", "node", "irb", "rails console"]
        if exactCommands.contains(command) {
            return true
        }

        let patterns = [
            "git commit",
            "git add -p",
            "git rebase -i",
            "npm init",
            "pnpm init",
            "yarn init",
            "npm login",
            "pnpm login",
            "yarn login",
            "npx create",
            "npm create",
            "pnpm create",
            "yarn create",
            "bunx create"
        ]

        if command.hasPrefix("git commit") && !command.contains(" -m ") && !command.contains(" --message ") {
            return true
        }

        return patterns.contains(where: { command.hasPrefix($0) })
    }

    private func isBackgroundCandidate(_ command: String, goalHint: String) -> Bool {
        let longRunningPatterns = [
            "npm run dev",
            "pnpm dev",
            "yarn dev",
            "vite",
            "next dev",
            "swift build --watch",
            "python -m http.server",
            "npm start"
        ]

        if longRunningPatterns.contains(where: { command.hasPrefix($0) }) {
            return true
        }

        if goalHint.contains("继续编码") || goalHint.contains("启动服务") || goalHint.contains("后台") {
            return command.contains("dev") || command.contains("server") || command.contains("watch")
        }

        return false
    }

    private func isForegroundCommand(_ command: String, goalHint: String) -> Bool {
        if command.contains("xcodebuild") || command.contains("swift test") || command.contains("npm test") {
            return true
        }

        if goalHint.contains("等待结果") || goalHint.contains("运行测试") || goalHint.contains("构建") {
            return true
        }

        return false
    }
}