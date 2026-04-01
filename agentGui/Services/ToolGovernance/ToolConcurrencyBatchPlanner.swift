import Foundation

/// Describes a group of tool calls scheduled for a single execution pass.
///
/// - `concurrent`: All tools in the batch are concurrency-safe (read-only)
///   and will be executed in parallel using a task group.
/// - `serial`: A single stateful or interactive tool that must run alone.
enum ToolExecutionBatch {
    case concurrent([AgentLoopPendingTool])
    case serial(AgentLoopPendingTool)
}

/// Partitions a flat list of pending tools into ordered execution batches.
///
/// Consecutive concurrency-safe tools are merged into a single `.concurrent`
/// batch. All other tools yield individual `.serial` batches.
///
/// The partitioning algorithm mirrors Claude Code's `partitionToolCalls()` in
/// `src/services/tools/toolOrchestration.ts`.
struct ToolConcurrencyBatchPlanner {

    /// Returns `true` when the named tool is safe to run concurrently with
    /// other tools that also return `true`. May throw; exceptions are treated
    /// conservatively as `false` (serial).
    let isConcurrencySafe: (String) throws -> Bool

    /// Partition `tools` into an ordered sequence of execution batches.
    ///
    /// - Note (S-F3 reservation): When the Fork concurrent subagent dispatcher
    ///   (S-F3 in `2026-04-01-subagent-capability-enhancement-design.md`) is implemented,
    ///   fork-mode subagents should be classified as concurrency-safe here by inspecting
    ///   `tool.subagentType` (or an equivalent annotation on `AgentLoopPendingTool`).  
    ///   Add a branch before the `isConcurrencySafe` check, e.g.:
    ///   ```swift
    ///   if tool.subagentType == .fork { /* treat as safe */ }
    ///   ```
    func partition(_ tools: [AgentLoopPendingTool]) -> [ToolExecutionBatch] {
        tools.reduce(into: [ToolExecutionBatch]()) { batches, tool in
            let safe = (try? isConcurrencySafe(tool.name)) ?? false
            if safe, case .concurrent(var existing) = batches.last {
                // Merge into the current open concurrent batch.
                existing.append(tool)
                batches[batches.count - 1] = .concurrent(existing)
            } else if safe {
                batches.append(.concurrent([tool]))
            } else {
                batches.append(.serial(tool))
            }
        }
    }
}

extension ToolConcurrencyBatchPlanner {
    /// Convenience initialiser that queries a `ToolRegistry` for safety metadata.
    init(registry: some ToolRegistry) {
        self.isConcurrencySafe = { name in
            registry.definition(for: name)?.isConcurrencySafe ?? false
        }
    }
}
