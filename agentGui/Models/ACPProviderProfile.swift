import Foundation
import SwiftData

struct ACPProviderProfileDraft: Equatable, Sendable {
    var id: UUID?
    var displayName: String
    var executablePath: String
    var arguments: [String]
    var isEnabled: Bool
    var sortOrder: Int?
    var validationSnapshot: ACPProviderValidationSnapshot?

    init(
        id: UUID? = nil,
        displayName: String,
        executablePath: String,
        arguments: [String] = [],
        isEnabled: Bool = true,
        sortOrder: Int? = nil,
        validationSnapshot: ACPProviderValidationSnapshot? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.executablePath = executablePath
        self.arguments = arguments
        self.isEnabled = isEnabled
        self.sortOrder = sortOrder
        self.validationSnapshot = validationSnapshot
    }
}

@Model
final class ACPProviderProfile {
    var id: UUID
    var displayName: String
    var executablePath: String
    var argumentsJSON: String
    var isEnabled: Bool
    var sortOrder: Int
    var discoveredAgentInfoJSON: String
    var discoveredCapabilitiesJSON: String
    var discoveredAuthMethodsJSON: String
    var lastValidationStatusRaw: String
    var lastValidationMessage: String
    var lastResolvedExecutablePath: String
    var lastVerifiedAt: Date?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        displayName: String,
        executablePath: String,
        arguments: [String] = [],
        isEnabled: Bool = true,
        sortOrder: Int = 0,
        validationSnapshot: ACPProviderValidationSnapshot? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.displayName = displayName
        self.executablePath = executablePath
        self.argumentsJSON = (try? String(data: JSONEncoder().encode(arguments), encoding: .utf8)) ?? "[]"
        self.isEnabled = isEnabled
        self.sortOrder = sortOrder
        self.discoveredAgentInfoJSON = ""
        self.discoveredCapabilitiesJSON = ""
        self.discoveredAuthMethodsJSON = "[]"
        self.lastValidationStatusRaw = ACPProviderValidationStatus.unknown.rawValue
        self.lastValidationMessage = ""
        self.lastResolvedExecutablePath = ""
        self.lastVerifiedAt = nil
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.validationSnapshot = validationSnapshot
    }
}

extension ACPProviderProfile {
    var arguments: [String] {
        get {
            guard let data = argumentsJSON.data(using: .utf8),
                  let arguments = try? JSONDecoder().decode([String].self, from: data) else {
                return []
            }
            return arguments
        }
        set {
            argumentsJSON = (try? String(data: JSONEncoder().encode(newValue), encoding: .utf8)) ?? "[]"
        }
    }

    var validationSnapshot: ACPProviderValidationSnapshot? {
        get {
            let agentInfo = decodedValue(ACPImplementation.self, from: discoveredAgentInfoJSON)
            let agentCapabilities = decodedValue(ACPAgentCapabilities.self, from: discoveredCapabilitiesJSON)
            let authMethods = decodedValue([ACPAuthMethod].self, from: discoveredAuthMethodsJSON) ?? []
            let status = ACPProviderValidationStatus(rawValue: lastValidationStatusRaw) ?? .unknown

            if agentInfo == nil,
               agentCapabilities == nil,
               authMethods.isEmpty,
               status == .unknown,
               lastValidationMessage.isEmpty,
               lastResolvedExecutablePath.isEmpty,
               lastVerifiedAt == nil {
                return nil
            }

            return ACPProviderValidationSnapshot(
                agentInfo: agentInfo,
                agentCapabilities: agentCapabilities,
                authMethods: authMethods,
                status: status,
                message: lastValidationMessage,
                resolvedExecutablePath: lastResolvedExecutablePath,
                verifiedAt: lastVerifiedAt
            )
        }
        set {
            guard let newValue else {
                discoveredAgentInfoJSON = ""
                discoveredCapabilitiesJSON = ""
                discoveredAuthMethodsJSON = "[]"
                lastValidationStatusRaw = ACPProviderValidationStatus.unknown.rawValue
                lastValidationMessage = ""
                lastResolvedExecutablePath = ""
                lastVerifiedAt = nil
                return
            }

            discoveredAgentInfoJSON = encodedString(newValue.agentInfo) ?? ""
            discoveredCapabilitiesJSON = encodedString(newValue.agentCapabilities) ?? ""
            discoveredAuthMethodsJSON = encodedString(newValue.authMethods) ?? "[]"
            lastValidationStatusRaw = newValue.status.rawValue
            lastValidationMessage = newValue.message
            lastResolvedExecutablePath = newValue.resolvedExecutablePath
            lastVerifiedAt = newValue.verifiedAt
        }
    }

    private func decodedValue<T: Decodable>(_ type: T.Type, from string: String) -> T? {
        guard let data = string.data(using: .utf8), string.isEmpty == false else {
            return nil
        }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func encodedString<T: Encodable>(_ value: T?) -> String? {
        guard let value else {
            return nil
        }
        return try? String(data: JSONEncoder().encode(value), encoding: .utf8)
    }
}