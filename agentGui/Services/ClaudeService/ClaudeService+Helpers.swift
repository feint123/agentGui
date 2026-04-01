//
//  ClaudeService+Helpers.swift
//  agentGui
//

import Foundation
import SwiftAnthropic

// MARK: - Module-level helper

/// Recursively convert DynamicContent (Decodable-only) to a JSONSerialization-compatible Any.
/// Exposed as a module-level function so hooks and non-service types can call it without a
/// ClaudeService reference.
func dynamicContentToAny(_ content: MessageResponse.Content.DynamicContent) -> Any {
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

// MARK: - Helper Methods

extension ClaudeService {

    /// Convenience wrapper so existing call-sites remain unchanged.
    internal func dynamicContentToAny(_ content: MessageResponse.Content.DynamicContent) -> Any {
        agentGui.dynamicContentToAny(content)
    }
}
