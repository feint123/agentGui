//
//  ClaudeService+DynamicContent.swift
//  agentGui
//

import Foundation
import SwiftAnthropic

// MARK: - DynamicContent Helpers

extension MessageResponse.Content.DynamicContent {
    var stringValue: String? {
        guard case .string(let s) = self else { return nil }
        return s
    }
    var intValue: Int? {
        switch self {
        case .integer(let i): return i
        case .double(let d): return Int(d)
        case .string(let s): return Int(s)
        default: return nil
        }
    }
    var arrayValue: [MessageResponse.Content.DynamicContent]? {
        guard case .array(let a) = self else { return nil }
        return a
    }
    var boolValue: Bool? {
        guard case .bool(let b) = self else { return nil }
        return b
    }
}

// MARK: - Errors

enum ClaudeError: LocalizedError {
    case notConfigured
    case streamFailed(Error)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "请先在设置中配置 Anthropic API 密钥"
        case .streamFailed(let error):
            return "请求失败: \(error.localizedDescription)"
        }
    }
}
