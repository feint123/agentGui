// agentGui/Models/LSPSignatureHelpModels.swift

import Foundation

// MARK: - Parameter Label

/// 参数标签：来自 LSP spec，可以是字符串或 [start, end] 偏移区间。
enum LSPParameterLabel: Sendable, Equatable {
    case text(String)
    case range(Int, Int)   // 半开区间：[start, end) in the signature label bytes
}

// MARK: - Parameter Information

struct LSPParameterInformation: Sendable {
    let label: LSPParameterLabel
    let documentation: String?

    init(label: LSPParameterLabel, documentation: String?) {
        self.label = label
        self.documentation = documentation
    }

    /// 从 LSP raw dict 解析
    init(raw: [String: Any]) throws {
        let labelRaw = raw["label"]
        if let s = labelRaw as? String {
            self.label = .text(s)
        } else if let arr = labelRaw as? [Int], arr.count == 2 {
            self.label = .range(arr[0], arr[1])
        } else {
            throw LSPSignatureHelpParseError.missingField("parameters[].label")
        }

        if let docStr = raw["documentation"] as? String {
            self.documentation = docStr
        } else if let docObj = raw["documentation"] as? [String: Any],
                  let value = docObj["value"] as? String {
            self.documentation = value
        } else {
            self.documentation = nil
        }
    }
}

// MARK: - Signature Information

struct LSPSignatureInformation: Sendable {
    let label: String
    let documentation: String?
    let parameters: [LSPParameterInformation]
    /// signature-level activeParameter（LSP 3.16+），优先于顶层字段
    let activeParameter: Int?

    init(label: String, documentation: String?, parameters: [LSPParameterInformation], activeParameter: Int?) {
        self.label = label
        self.documentation = documentation
        self.parameters = parameters
        self.activeParameter = activeParameter
    }

    init(raw: [String: Any]) throws {
        guard let label = raw["label"] as? String else {
            throw LSPSignatureHelpParseError.missingField("signatures[].label")
        }
        self.label = label

        if let docStr = raw["documentation"] as? String {
            self.documentation = docStr
        } else if let docObj = raw["documentation"] as? [String: Any],
                  let value = docObj["value"] as? String {
            self.documentation = value
        } else {
            self.documentation = nil
        }

        let rawParams = (raw["parameters"] as? [[String: Any]]) ?? []
        self.parameters = try rawParams.map { try LSPParameterInformation(raw: $0) }
        self.activeParameter = raw["activeParameter"] as? Int
    }
}

// MARK: - Signature Help (top-level result)

struct LSPSignatureHelp: Sendable {
    let signatures: [LSPSignatureInformation]
    let activeSignature: Int
    let activeParameter: Int    // 顶层 fallback

    var isValid: Bool { !signatures.isEmpty }

    /// 解析活跃参数索引：per-signature 优先（LSP 3.16 spec §3.16.0）
    func resolvedActiveParameter(for signatureIndex: Int) -> Int {
        guard signatureIndex < signatures.count else { return activeParameter }
        return signatures[signatureIndex].activeParameter ?? activeParameter
    }

    /// 当前活跃签名（安全边界检查）
    var activeSignatureInfo: LSPSignatureInformation? {
        guard activeSignature < signatures.count else { return nil }
        return signatures[activeSignature]
    }
}

// MARK: - Trigger Context

enum LSPSignatureHelpTriggerKind: Int, Sendable {
    case invoked = 1
    case triggerCharacter = 2
    case contentChange = 3
}

struct SignatureHelpTriggerContext: Sendable {
    let triggerKind: LSPSignatureHelpTriggerKind
    let triggerCharacter: String?
    let isRetrigger: Bool
    /// 前一次的活跃结果，用于 retrigger（VSCode 会传回服务器）
    let activeSignatureHelp: LSPSignatureHelp?
}

// MARK: - Errors

enum LSPSignatureHelpParseError: Error {
    case missingField(String)
}

// MARK: - Parser

enum LSPClientSignatureHelpParser {
    static func parse(raw: Any?) throws -> LSPSignatureHelp? {
        guard let dict = raw as? [String: Any] else { return nil }

        let rawSigs = (dict["signatures"] as? [[String: Any]]) ?? []
        if rawSigs.isEmpty { return nil }

        let signatures = try rawSigs.map { try LSPSignatureInformation(raw: $0) }
        let activeSignature = (dict["activeSignature"] as? Int) ?? 0
        let activeParameter = (dict["activeParameter"] as? Int) ?? 0

        let help = LSPSignatureHelp(
            signatures: signatures,
            activeSignature: max(0, min(activeSignature, signatures.count - 1)),
            activeParameter: activeParameter
        )
        return help.isValid ? help : nil
    }
}
