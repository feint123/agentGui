// agentGui/Models/DiagSeverity.swift
import Foundation

/// LSP 诊断严重度（Comparable：error 最严重）。
enum DiagSeverity: Int, Comparable, Sendable, CaseIterable {
    case error   = 0
    case warning = 1
    case hint    = 2

    static func < (lhs: DiagSeverity, rhs: DiagSeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
