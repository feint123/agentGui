import Foundation
import SwiftAnthropic

enum BashToolOperationRouterError: LocalizedError, Equatable {
    case invalidOperation(String)
    case missingTaskID(BashToolOperation)
    case missingCommand
    case invalidExecutionMode(String)
    case unsupportedLegacyField(String)

    var errorDescription: String? {
        switch self {
        case .invalidOperation(let value):
            return "Error: invalid operation '\(value)'"
        case .missingTaskID(let operation):
            return "Error: operation '\(operation.rawValue)' requires 'task_id'"
        case .missingCommand:
            return "Error: missing 'command' parameter"
        case .invalidExecutionMode(let value):
            return "Error: invalid execution_mode '\(value)'"
        case .unsupportedLegacyField(let field):
            return "Error: legacy bash field '\(field)' is no longer supported"
        }
    }
}

struct BashToolOperationRouter {
    func parse(input: MessageResponse.Content.Input) throws -> BashToolOperationRequest {
        print("[bash-router] parse input keys=\(Array(input.keys).sorted()) operation=\(input["operation"]?.stringValue ?? "nil") task_id=\(input["task_id"]?.stringValue ?? "nil")")
        try rejectLegacyFields(in: input)

        let taskId = input["task_id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedTaskId = taskId?.isEmpty == true ? nil : taskId
        let command = input["command"]?.stringValue
        let rawOperation = input["operation"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let usesImplicitStart = (rawOperation == nil || rawOperation?.isEmpty == true)
            && command?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false

        let operation: BashToolOperation
        if usesImplicitStart {
            operation = .start
        } else {
            guard let rawOperation, !rawOperation.isEmpty else {
                throw BashToolOperationRouterError.invalidOperation("")
            }
            guard let parsedOperation = BashToolOperation(rawValue: rawOperation) else {
                throw BashToolOperationRouterError.invalidOperation(rawOperation)
            }
            operation = parsedOperation
        }

        let executionMode = try parseExecutionMode(input["execution_mode"]?.stringValue)
        let timeout = input["timeout"]?.intValue.map(TimeInterval.init)
        let inputText = input["input"]?.stringValue
        let force = input["force"]?.boolValue ?? false
        let tailLines = input["tail_lines"]?.intValue

        let request = BashToolOperationRequest(
            operation: operation,
            taskId: normalizedTaskId,
            command: command,
            executionMode: executionMode,
            input: inputText,
            timeout: timeout,
            force: force,
            tailLines: tailLines
        )

        switch operation {
        case .start:
            if !usesImplicitStart {
                guard let taskId = request.taskId, !taskId.isEmpty else {
                    print("[bash-router] start missing task_id")
                    throw BashToolOperationRouterError.missingTaskID(operation)
                }
            }
            guard let command = request.command?.trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty else {
                print("[bash-router] start missing task_id")
                print("[bash-router] start missing command task_id=\(request.taskId ?? "nil")")
                throw BashToolOperationRouterError.missingCommand
            }
        case .sendInput, .interrupt, .terminate, .status, .readOutput, .cleanup:
            guard let taskId = request.taskId, !taskId.isEmpty else {
                print("[bash-router] operation=\(operation.rawValue) missing task_id")
                throw BashToolOperationRouterError.missingTaskID(operation)
            }
        }

        print("[bash-router] parsed operation=\(request.operation.rawValue) task_id=\(request.taskId ?? "nil") mode=\(request.executionMode.rawValue)")

        return request
    }

    private func parseExecutionMode(_ rawValue: String?) throws -> TerminalExecutionMode {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines), !rawValue.isEmpty else {
            return .attached
        }
        guard let mode = TerminalExecutionMode(rawValue: rawValue) else {
            throw BashToolOperationRouterError.invalidExecutionMode(rawValue)
        }
        return mode
    }

    private func rejectLegacyFields(in input: MessageResponse.Content.Input) throws {
        let legacyFields = ["background", "interactive", "interrupt", "signal", "goal_hint", "scan_policy", "auto_reply_policy", "restart"]
        for field in legacyFields where input[field] != nil {
            throw BashToolOperationRouterError.unsupportedLegacyField(field)
        }
    }
}