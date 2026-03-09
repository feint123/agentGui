//
//  ClaudeService+Helpers.swift
//  agentGui
//

import Foundation
import SwiftAnthropic

// MARK: - Helper Methods

extension ClaudeService {

    /// Recursively convert DynamicContent (Decodable-only) to a JSONSerialization-compatible Any.
    internal func dynamicContentToAny(_ content: MessageResponse.Content.DynamicContent) -> Any {
        switch content {
        case .string(let s):  return s
        case .integer(let i): return i
        case .double(let d):  return d
        case .bool(let b):    return b
        case .null:           return NSNull()
        case .array(let arr): return arr.map { dynamicContentToAny($0) }
        case .dictionary(let dict):
            return dict.mapValues { dynamicContentToAny($0) }
        }
    }
}
