import Foundation
import SwiftAnthropic
import Testing
@testable import agentGui

struct BashToolOperationRouterTests {

    @Test func commandOnlyInputDefaultsToStartOperationForCompatibility() throws {
        let router = BashToolOperationRouter()

        let request = try router.parse(input: [
            "command": .string("printf 'hello'")
        ])

        #expect(request.operation == .start)
        #expect(request.command == "printf 'hello'")
        #expect(request.taskId == nil)
        #expect(request.executionMode == .attached)
    }

    @Test func startRequiresTaskIdAndCommand() throws {
        let router = BashToolOperationRouter()

        #expect(throws: BashToolOperationRouterError.self) {
            _ = try router.parse(input: [
                "operation": .string("start"),
                "command": .string("echo hello")
            ])
        }

        #expect(throws: BashToolOperationRouterError.self) {
            _ = try router.parse(input: [
                "operation": .string("start"),
                "task_id": .string("task-1")
            ])
        }
    }

    @Test func operationAcceptsOnlyPtyContractValues() throws {
        let router = BashToolOperationRouter()

        #expect(throws: BashToolOperationRouterError.self) {
            _ = try router.parse(input: [
                "operation": .string("resume"),
                "task_id": .string("task-1")
            ])
        }
    }

    @Test func legacyFlagsAreRejected() throws {
        let router = BashToolOperationRouter()

        #expect(throws: BashToolOperationRouterError.self) {
            _ = try router.parse(input: [
                "command": .string("echo hello"),
                "background": .bool(true),
                "task_id": .string("task-1")
            ])
        }
    }

    @Test func startParsesAttachedAndDetachedOperations() throws {
        let router = BashToolOperationRouter()

        let attached = try router.parse(input: [
            "operation": .string("start"),
            "command": .string("echo hello"),
            "task_id": .string("task-attached"),
            "execution_mode": .string("attached")
        ])
        let detached = try router.parse(input: [
            "operation": .string("start"),
            "command": .string("npm run dev"),
            "task_id": .string("task-detached"),
            "execution_mode": .string("detached")
        ])

        #expect(attached.operation == .start)
        #expect(attached.executionMode == .attached)
        #expect(detached.executionMode == .detached)
    }

    @Test func explicitStartStillRequiresTaskId() throws {
        let router = BashToolOperationRouter()

        #expect(throws: BashToolOperationRouterError.self) {
            _ = try router.parse(input: [
                "operation": .string("start"),
                "command": .string("echo hello")
            ])
        }
    }
}