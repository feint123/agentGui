// agentGui/Services/Editor/CodeEditorGhostTextService.swift
import Foundation
import SwiftAnthropic

// MARK: - GhostTextClient 协议

/// 抽象 AI 请求层，测试时可 mock
protocol GhostTextClientProtocol: Sendable {
    func streamCompletion(
        prefix: String,
        suffix: String,
        language: String,
        modelId: String
    ) async throws -> AsyncThrowingStream<String, Error>
}

// MARK: - AnthropicGhostTextClient（生产实现）

struct AnthropicGhostTextClient: GhostTextClientProtocol {
    let service: any AnthropicService

    func streamCompletion(
        prefix: String,
        suffix: String,
        language: String,
        modelId: String
    ) async throws -> AsyncThrowingStream<String, Error> {
        let prompt = Self.buildPrompt(prefix: prefix, suffix: suffix, language: language)
        let params = MessageParameter(
            model: .other(modelId),
            messages: [.init(role: .user, content: .text(prompt))],
            maxTokens: 512,
            system: .text("You are a code completion assistant. Return ONLY the code to insert at the cursor position, no explanation, no markdown fences.")
        )
        let rawStream = try await service.streamMessage(params)
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    for try await event in rawStream {
                        if let delta = event.delta,
                           delta.type == "text_delta",
                           let chunk = delta.text {
                            continuation.yield(chunk)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    static func buildPrompt(prefix: String, suffix: String, language: String) -> String {
        """
        Complete the following \(language) code at the cursor position marked with <CURSOR>.
        Return ONLY the code to insert. Do not repeat code before or after the cursor.

        Code before cursor:
        \(prefix)
        <CURSOR>
        Code after cursor:
        \(suffix)
        """
    }
}

// MARK: - CodeEditorGhostTextService

@MainActor
final class CodeEditorGhostTextService {

    private let client: any GhostTextClientProtocol
    private var currentTask: Task<Void, Never>?
    private var currentGeneration: Int = 0
    let modelId: String

    init(client: any GhostTextClientProtocol, modelId: String = "claude-haiku-4-5") {
        self.client = client
        self.modelId = modelId
    }

    /// 发起 ghost text 请求（fire-and-forget）。若有进行中的请求，先取消。
    ///
    /// - Parameters:
    ///   - generation: 请求代际（调用方每次递增）
    ///   - onFirstLine: 首行文字到达时回调（从后台线程调用，调用方自行 dispatch 到 main）
    ///   - onComplete: 完整文本回调（从后台线程调用）
    ///   - onCancel: 取消回调（从后台线程调用）
    func request(
        prefix: String,
        suffix: String,
        language: String,
        generation: Int,
        onFirstLine: @escaping @Sendable (String) -> Void,
        onComplete: @escaping @Sendable (String) -> Void,
        onCancel: @escaping @Sendable () -> Void
    ) {
        // 取消旧请求
        currentTask?.cancel()
        currentGeneration = generation

        let capturedClient = client
        let capturedModelId = modelId

        currentTask = Task.detached {
            var accumulated = ""
            var firstLineDelivered = false
            var wasCancelled = false

            do {
                let stream = try await capturedClient.streamCompletion(
                    prefix: prefix,
                    suffix: suffix,
                    language: language,
                    modelId: capturedModelId
                )

                try await withTaskCancellationHandler {
                    for try await chunk in stream {
                        try Task.checkCancellation()
                        accumulated += chunk

                        // 首行到达即刻回写
                        if !firstLineDelivered, accumulated.contains("\n") || accumulated.count > 10 {
                            let firstLine = accumulated.components(separatedBy: "\n").first ?? accumulated
                            if !firstLine.isEmpty {
                                onFirstLine(firstLine)
                                firstLineDelivered = true
                            }
                        }
                    }
                } onCancel: {
                    wasCancelled = true
                    onCancel()
                }

                guard !wasCancelled else { return }
                let result = accumulated.trimmingCharacters(in: CharacterSet(charactersIn: "\n"))
                guard !result.isEmpty else { return }
                onComplete(result)

            } catch is CancellationError {
                if !wasCancelled { onCancel() }
            } catch {
                // 网络/API 错误静默忽略，不向用户展示
            }
        }
    }

    /// 立即取消当前进行中的请求
    func cancel() {
        currentTask?.cancel()
        currentTask = nil
    }
}
