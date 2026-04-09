// agentGuiTests/GhostTextTestHelpers.swift
import Foundation
@testable import agentGui

// MARK: - AppSettings Test Helper

extension AppSettings {
    /// 用于 Ghost Text 单元测试的 mock 实例（默认值全部为 false / 0）
    static var ghostTextMock: AppSettings {
        AppSettings()
    }
}

// MARK: - MockGhostTextClient

final class MockGhostTextClient: GhostTextClientProtocol, @unchecked Sendable {
    var requestCalled = false
    var completedGenerations: [Int] = []

    func streamCompletion(
        prefix: String, suffix: String, language: String, modelId: String
    ) async throws -> AsyncThrowingStream<String, Error> {
        requestCalled = true
        return AsyncThrowingStream { continuation in
            continuation.yield("mock response")
            continuation.finish()
        }
    }
}

// MARK: - SlowMockGhostTextClient

final class SlowMockGhostTextClient: GhostTextClientProtocol, @unchecked Sendable {
    func streamCompletion(
        prefix: String, suffix: String, language: String, modelId: String
    ) async throws -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let innerTask = Task {
                do {
                    try await Task.sleep(nanoseconds: 500_000_000) // 500ms — cancellation-aware
                    continuation.yield("slow result")
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            // When consumer task is cancelled, propagate cancellation to inner task
            continuation.onTermination = { _ in innerTask.cancel() }
        }
    }
}

// MARK: - EmptyMockGhostTextClient

final class EmptyMockGhostTextClient: GhostTextClientProtocol, @unchecked Sendable {
    func streamCompletion(
        prefix: String, suffix: String, language: String, modelId: String
    ) async throws -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

// MARK: - ErrorMockGhostTextClient

final class ErrorMockGhostTextClient: GhostTextClientProtocol, @unchecked Sendable {
    func streamCompletion(
        prefix: String, suffix: String, language: String, modelId: String
    ) async throws -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish(throwing: URLError(.notConnectedToInternet)) }
    }
}
