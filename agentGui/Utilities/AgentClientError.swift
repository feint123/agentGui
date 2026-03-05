//
//  AgentClientError.swift
//  agentGui
//
//  Created by feint on 2026/2/10.
//

import Foundation

/// 应用错误类型
enum AgentClientError: LocalizedError, CustomStringConvertible {
    case agentNotFound(path: String)
    case connectionFailed(underlying: Error)
    case authenticationFailed
    case sessionCreationFailed
    case promptFailed(underlying: Error)
    case permissionDenied
    case dataCorrupted
    case invalidConfiguration
    case operationTimeout
    case processNotRunning
    case processFailed(exitCode: Int32)

    var errorDescription: String? {
        switch self {
        case .agentNotFound(let path):
            return "无法找到 Agent: \(path)"
        case .connectionFailed(let error):
            return "连接失败: \(error.localizedDescription)"
        case .authenticationFailed:
            return "认证失败，请检查 API 密钥或令牌"
        case .sessionCreationFailed:
            return "创建会话失败"
        case .promptFailed(let error):
            return "发送提示失败: \(error.localizedDescription)"
        case .permissionDenied:
            return "权限被拒绝"
        case .dataCorrupted:
            return "数据已损坏，请联系支持"
        case .invalidConfiguration:
            return "配置无效，请检查 Agent 设置"
        case .operationTimeout:
            return "操作超时，请重试"
        case .processNotRunning:
            return "Agent 进程未运行"
        case .processFailed(let exitCode):
            return "Agent 进程异常退出，退出码: \(exitCode)"
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .agentNotFound:
            return "请检查 Agent 路径是否正确，或重新安装 Agent"
        case .connectionFailed:
            return "请检查网络连接和 Agent 服务状态"
        case .authenticationFailed:
            return "请更新 API 密钥或令牌后重试"
        case .sessionCreationFailed:
            return "请检查工作目录是否存在且有访问权限"
        case .promptFailed:
            return "请检查提示内容是否合规，或稍后重试"
        case .permissionDenied:
            return "如果您希望允许此操作，请在权限请求对话框中批准"
        case .dataCorrupted:
            return "尝试清除应用数据或重新安装应用"
        case .invalidConfiguration:
            return "请在设置中检查 Agent 配置"
        case .operationTimeout:
            return "请检查 Agent 是否响应，或尝试重新连接"
        case .processNotRunning:
            return "请先启动 Agent"
        case .processFailed:
            return "请检查 Agent 日志以了解失败原因"
        }
    }

    var description: String {
        return errorDescription ?? "未知错误"
    }
}

/// Agent 连接状态
enum AgentConnectionState: Sendable, Equatable {
    case disconnected
    case connecting
    case connected(agentInfo: AgentInfo)
    case error(String)

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

/// Agent 信息
struct AgentInfo: Sendable, Codable, Equatable {
    let name: String
    let version: String
    let protocolVersion: Int
    let capabilities: AgentCapabilities?

    init(
        name: String,
        version: String,
        protocolVersion: Int = 1,
        capabilities: AgentCapabilities? = nil
    ) {
        self.name = name
        self.version = version
        self.protocolVersion = protocolVersion
        self.capabilities = capabilities
    }
}

/// Agent 能力
struct AgentCapabilities: Sendable, Codable, Equatable {
    let supportsStreaming: Bool
    let supportsTools: Bool
    let supportsModes: Bool

    init(
        supportsStreaming: Bool = true,
        supportsTools: Bool = true,
        supportsModes: Bool = false
    ) {
        self.supportsStreaming = supportsStreaming
        self.supportsTools = supportsTools
        self.supportsModes = supportsModes
    }
}
