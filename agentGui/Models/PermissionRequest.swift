//
//  PermissionRequest.swift
//  agentGui
//
//  Created by feint on 2026/2/10.
//

import SwiftData
import Foundation

@Model
final class PermissionRequest {
    /// 唯一标识符
    var id: UUID

    /// 请求类型
    var requestType: PermissionType

    /// 目标资源路径
    var resourcePath: String

    /// 用户决定
    var decision: PermissionDecision

    /// 是否记住选择
    var rememberChoice: Bool

    /// 请求时间
    var timestamp: Date

    /// 关联的会话
    var session: Session?

    init(
        requestType: PermissionType,
        resourcePath: String,
        session: Session? = nil
    ) {
        self.id = UUID()
        self.requestType = requestType
        self.resourcePath = resourcePath
        self.decision = .pending
        self.rememberChoice = false
        self.timestamp = Date()
        self.session = session
    }
}

// MARK: - Computed Properties
extension PermissionRequest {
    /// 是否待处理
    var isPending: Bool {
        decision == .pending
    }

    /// 是否已批准
    var isAllowed: Bool {
        decision == .allowed
    }

    /// 是否已拒绝
    var isDenied: Bool {
        decision == .denied
    }

    /// 格式化的资源显示
    var resourceDisplay: String {
        ACPAdapters.shortenPath(resourcePath)
    }
}

// MARK: - Factory Methods
extension PermissionRequest {
    /// 创建文件读取权限请求
    static func fileReadRequest(path: String, session: Session? = nil) -> PermissionRequest {
        PermissionRequest(requestType: .fileRead, resourcePath: path, session: session)
    }

    /// 创建文件写入权限请求
    static func fileWriteRequest(path: String, session: Session? = nil) -> PermissionRequest {
        PermissionRequest(requestType: .fileWrite, resourcePath: path, session: session)
    }

    /// 创建终端执行权限请求
    static func terminalRequest(command: String, session: Session? = nil) -> PermissionRequest {
        PermissionRequest(requestType: .terminalCreate, resourcePath: command, session: session)
    }
}
