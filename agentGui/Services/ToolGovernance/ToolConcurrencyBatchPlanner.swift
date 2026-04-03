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
    /// S-F3: Fork-mode subagents (`tool.isForkSubagent == true`) are treated as
    /// concurrency-safe regardless of their tool name, enabling multiple fork children
    /// dispatched in the same agent turn to execute in parallel (see S-F3 in
    /// `2026-04-01-subagent-capability-enhancement-design.md`).
    func partition(_ tools: [AgentLoopPendingTool]) -> [ToolExecutionBatch] {
        tools.reduce(into: [ToolExecutionBatch]()) { batches, tool in
            // S-F3: fork subagents are always concurrency-safe — checked BEFORE isConcurrencySafe
            // to avoid relying on run_subagent's ToolRegistry entry (which remains serial-safe
            // to keep non-fork subagents serialized).
            let safe = tool.isForkSubagent || ((try? isConcurrencySafe(tool.name)) ?? false)
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
