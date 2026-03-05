//
//  ACPClientService.swift
//  agentGui
//
//  Created by feint on 2026/2/10.
//

import Foundation
import ACP
import ACPModel

/// ACP 客户端服务 Actor，封装 swift-acp Client
actor ACPClientService {

    // MARK: - Properties

    private let client: Client
    private var activeSessions: [String: String] = [:]
    private var currentAgentInfo: AgentInfo?
    private var connectionState: ConnectionState = .disconnected

    // MARK: - Types

    /// 连接状态
    enum ConnectionState: Sendable {
        case disconnected
        case connecting
        case connected(agentInfo: AgentInfo)
        case error(String)

        var isConnected: Bool {
            if case .connected = self { return true }
            return false
        }
    }

    // MARK: - Initialization

    init() {
        self.client = Client()
    }

    // MARK: - Connection Management

    /// 连接 Agent
    func connect(agent: AgentConfiguration) async throws {
        connectionState = .connecting

        do {
            // 启动 Agent 进程
            if agent.isLocal {
                guard let path = agent.executablePath else {
                    throw AgentClientError.agentNotFound(path: "未指定")
                }
                let args = agent.arguments.isEmpty ? [] : agent.arguments
                try await client.launch(
                    agentPath: path,
                    arguments: args,
                    workingDirectory: agent.defaultWorkingDirectory
                )
            }

            // 初始化握手
            let initResponse = try await client.initialize(
                protocolVersion: 1,
                capabilities: ClientCapabilities(
                    fs: FileSystemCapabilities(readTextFile: true, writeTextFile: true),
                    terminal: true
                )
            )

            // 保存 Agent 信息
            if let agentInfo = initResponse.agentInfo {
                currentAgentInfo = AgentInfo(
                    name: agentInfo.name,
                    version: agentInfo.version,
                    protocolVersion: initResponse.protocolVersion,
                    capabilities: AgentCapabilities(
                        supportsStreaming: true,
                        supportsTools: true,
                        supportsModes: false
                    )
                )
            }

            connectionState = .connected(agentInfo: currentAgentInfo ?? AgentInfo(
                name: agent.name,
                version: "1.0.0"
            ))

        } catch {
            connectionState = .error(error.localizedDescription)
            throw AgentClientError.connectionFailed(underlying: error)
        }
    }

    /// 断开连接
    func disconnect() async {
        await client.terminate()
        activeSessions.removeAll()
        currentAgentInfo = nil
        connectionState = .disconnected
    }

    // MARK: - Session Management

    /// 创建会话
    func createSession(workingDirectory: String) async throws -> Session {
        guard connectionState.isConnected else {
            throw AgentClientError.sessionCreationFailed
        }

        let response = try await client.newSession(
            workingDirectory: workingDirectory,
            mcpServers: []
        )

        let sessionId = response.sessionId
        activeSessions[sessionId.value] = workingDirectory

        return Session(
            sessionId: sessionId.value,
            title: Session.generateTitle(from: workingDirectory),
            workingDirectory: workingDirectory
        )
    }

    /// 结束会话
    func closeSession(sessionId: String) async throws {
        activeSessions.removeValue(forKey: sessionId)
    }

    // MARK: - Messaging

    /// 发送提示
    func sendPrompt(text: String, sessionId: String) async throws {
        // TODO: 实现发送提示
    }

    /// 取消会话操作
    func cancelSession(sessionId: String) async throws {
        // TODO: 实现取消操作
    }

    /// 设置会话模式
    func setMode(sessionId: String, modeId: String) async throws {
        // TODO: 实现设置模式
    }

    // MARK: - Streaming Updates

    /// 订阅会话更新流
    func subscribeToUpdates(sessionId: String) -> AsyncStream<SessionUpdate> {
        AsyncStream { continuation in
            // TODO: 实现流式更新
            continuation.finish()
        }
    }

    // MARK: - State

    /// 当前连接状态
    func getConnectionState() -> ConnectionState {
        connectionState
    }

    /// Agent 信息
    func getAgentInfo() -> AgentInfo? {
        currentAgentInfo
    }

    /// 活跃会话列表
    func getActiveSessions() -> [String] {
        Array(activeSessions.keys)
    }
}

// MARK: - Session Update Types

/// 会话更新事件
enum SessionUpdate: Sendable {
    case messageChunk(String)
    case toolCall(ToolCallEvent)
    case modeChanged(SessionMode)
    case error(Error)
}

struct ToolCallEvent: Sendable {
    let toolCallId: String
    let kind: ToolKind
    let status: ToolStatus
    let title: String?
    let filePath: String?
}
