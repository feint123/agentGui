import SwiftAnthropic

// MARK: - InvariantViolation

/// 消息数组中发现的不变量违规。
enum InvariantViolation: Equatable, Sendable {
    /// 某条 user 消息中有 tool_result 块，但在该消息之前找不到对应的 tool_use。
    /// - Parameters:
    ///   - toolUseId: 孤立 tool_result 中的 toolUseId。
    ///   - messageIndex: 含有该 tool_result 的 user 消息在数组中的下标。
    case orphanToolResult(toolUseId: String, messageIndex: Int)

    /// 某条 assistant 消息中有 tool_use 块，但在整个数组中找不到对应的 tool_result。
    /// (警告级别：不一定导致 API 错误，但说明会话被异常截断。)
    /// - Parameters:
    ///   - toolCallId: 孤立 tool_use 的 id。
    ///   - messageIndex: 含有该 tool_use 的 assistant 消息在数组中的下标。
    case orphanToolUse(toolCallId: String, messageIndex: Int)
}

// MARK: - ValidationResult

/// `MessageInvariantValidator.validate(_:)` 的返回值。
struct ValidationResult: Equatable, Sendable {
    /// 数组中没有任何不变量违规。
    var isValid: Bool { violations.isEmpty }
    /// 所有发现的违规列表（空表示合法）。
    let violations: [InvariantViolation]

    static let valid = ValidationResult(violations: [])
}

// MARK: - MessageInvariantValidator

/// 纯无副作用的消息不变量校验器。
///
/// 在压缩操作截断 `[MessageParameter.Message]` 前调用，确保
/// `tool_use / tool_result` 配对完整，避免 Claude API 返回 400。
///
/// 不持有可变状态，任意线程可并发调用。
struct MessageInvariantValidator: Sendable {

    // MARK: - Internal Scanning Utilities

    /// 从单条 user 消息中收集所有 tool_result 的 toolUseId。
    func toolResultIds(in message: MessageParameter.Message) -> [String] {
        guard message.role == "user" else { return [] }
        guard case .list(let objects) = message.content else { return [] }
        return objects.compactMap { obj -> String? in
            if case .toolResult(let id, _, _, _) = obj { return id }
            return nil
        }
    }

    /// 从单条 assistant 消息中收集所有 tool_use 的 id。
    func toolUseIds(in message: MessageParameter.Message) -> [String] {
        guard message.role == "assistant" else { return [] }
        guard case .list(let objects) = message.content else { return [] }
        return objects.compactMap { obj -> String? in
            if case .toolUse(let id, _, _) = obj { return id }
            return nil
        }
    }

    // MARK: - Public API

    /// 调整拟定截断起点，确保 kept range `messages[adjustedIndex...]` 中
    /// 所有 tool_result 都能在 kept range 内找到对应的 tool_use。
    ///
    /// - Parameters:
    ///   - proposedStart: 拟定的截断起点（压缩方希望保留 `messages[proposedStart...]`）。
    ///   - messages: 完整消息数组（包含截断前的所有消息）。
    /// - Returns: 安全的截断起点（≤ proposedStart），保证配对完整。
    ///
    /// 对应 Claude Code `adjustIndexToPreserveAPIInvariants()`。
    func adjustedStartIndex(_ proposedStart: Int, in messages: [MessageParameter.Message]) -> Int {
        guard proposedStart > 0, proposedStart <= messages.count else {
            return proposedStart
        }

        var adjustedIndex = proposedStart

        // Step 1: 收集 kept range 中所有 tool_result 需要的 toolUseId
        var neededToolUseIds: Set<String> = []
        for i in adjustedIndex..<messages.count {
            neededToolUseIds.formUnion(toolResultIds(in: messages[i]))
        }

        guard !neededToolUseIds.isEmpty else { return adjustedIndex }

        // Step 2: 剔除 kept range 内已经存在的 tool_use id（它们不需要向前查找）
        for i in adjustedIndex..<messages.count {
            let presentIds = toolUseIds(in: messages[i])
            neededToolUseIds.subtract(presentIds)
        }

        // Step 3: 向前扫描，找到缺失的 tool_use
        var i = adjustedIndex - 1
        while i >= 0, !neededToolUseIds.isEmpty {
            let foundIds = toolUseIds(in: messages[i])
            let intersect = neededToolUseIds.intersection(foundIds)
            if !intersect.isEmpty {
                adjustedIndex = i
                neededToolUseIds.subtract(intersect)
            }
            i -= 1
        }

        return adjustedIndex
    }

    /// 全量扫描 `messages`，检测所有 tool_use/tool_result 配对违规。
    /// 使用场景：压缩前断言、调试、测试。
    ///
    /// 校验规则：
    /// 1. 每个 tool_result 的 toolUseId 必须能在**前面**（较小下标）的 assistant 消息中找到对应 tool_use。
    /// 2. 每个 tool_use 的 id 必须能在**后面**（较大下标）的 user 消息中找到对应 tool_result。
    ///
    /// - Returns: `ValidationResult`，包含所有违规（空 = 合法）。
    func validate(_ messages: [MessageParameter.Message]) -> ValidationResult {
        // 建立 toolUseId → messageIndex 的映射（仅 assistant 消息）
        var toolUseIndexByID: [String: Int] = [:]
        // 追踪每个 tool_use 是否被 tool_result 响应
        var pendingToolUseIds: Set<String> = []

        var violations: [InvariantViolation] = []

        for (idx, message) in messages.enumerated() {
            if message.role == "assistant" {
                let ids = toolUseIds(in: message)
                for id in ids {
                    toolUseIndexByID[id] = idx
                    pendingToolUseIds.insert(id)
                }
            } else if message.role == "user" {
                let ids = toolResultIds(in: message)
                for id in ids {
                    if toolUseIndexByID[id] == nil {
                        // 没有前置 tool_use：孤立 tool_result
                        violations.append(.orphanToolResult(toolUseId: id, messageIndex: idx))
                    } else {
                        pendingToolUseIds.remove(id)
                    }
                }
            }
        }

        // 剩余未被响应的 tool_use
        for id in pendingToolUseIds {
            if let idx = toolUseIndexByID[id] {
                violations.append(.orphanToolUse(toolCallId: id, messageIndex: idx))
            }
        }

        return ValidationResult(violations: violations)
    }
}
