//
//  AgentClientError.swift
//  agentGui
//
//  Created by feint on 2026/2/10.
//

import Foundation

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

    init(supportsStreaming: Bool = true, supportsTools: Bool = false) {
        self.supportsStreaming = supportsStreaming
        self.supportsTools = supportsTools
    }
}
