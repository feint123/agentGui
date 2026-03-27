import Foundation
import SwiftData

@MainActor
struct ACPExternalSessionBindingStore {
    let modelContext: ModelContext

    func binding(for sessionID: String, providerReference: ExecutionProviderReference) throws -> ACPExternalSessionBinding? {
        let bindings = try modelContext.fetch(FetchDescriptor<ACPExternalSessionBinding>())
        return bindings.first(where: {
            $0.localSessionID == sessionID && $0.providerReference == providerReference
        })
    }

    func binding(for sessionID: String, providerID: ConversationExecutionProviderID) throws -> ACPExternalSessionBinding? {
        let bindings = try modelContext.fetch(FetchDescriptor<ACPExternalSessionBinding>())
        return bindings.first(where: {
            $0.localSessionID == sessionID && $0.providerID == providerID
        })
    }

    @discardableResult
    func upsert(
        sessionID: String,
        providerReference: ExecutionProviderReference,
        remoteSessionID: String,
        agentVersion: String?,
        capabilities: ACPExternalAgentCapabilitySnapshot?,
        selectedModel: String?,
        selectedAgentName: String?
    ) throws -> ACPExternalSessionBinding {
        let now = Date()
        let binding = try binding(for: sessionID, providerReference: providerReference) ?? {
            let newBinding = ACPExternalSessionBinding(
                localSessionID: sessionID,
                providerIDRaw: providerReference.persistedValue,
                remoteSessionID: remoteSessionID,
                createdAt: now,
                updatedAt: now
            )
            modelContext.insert(newBinding)
            return newBinding
        }()

        binding.providerReference = providerReference
        binding.remoteSessionID = remoteSessionID
        binding.agentVersion = agentVersion ?? ""
        binding.negotiatedCapabilities = capabilities
        binding.lastSelectedModel = selectedModel ?? ""
        binding.lastSelectedAgentName = selectedAgentName ?? ""
        binding.lastHandshakeAt = now
        binding.updatedAt = now
        try modelContext.save()
        return binding
    }

    @discardableResult
    func upsert(
        sessionID: String,
        providerID: ConversationExecutionProviderID,
        remoteSessionID: String,
        agentVersion: String?,
        capabilities: ACPExternalAgentCapabilitySnapshot?,
        selectedModel: String?,
        selectedAgentName: String?
    ) throws -> ACPExternalSessionBinding {
        let now = Date()
        let binding = try binding(for: sessionID, providerID: providerID) ?? {
            let newBinding = ACPExternalSessionBinding(
                localSessionID: sessionID,
                providerIDRaw: providerID.rawValue,
                remoteSessionID: remoteSessionID,
                createdAt: now,
                updatedAt: now
            )
            modelContext.insert(newBinding)
            return newBinding
        }()

        binding.providerIDRaw = providerID.rawValue
        binding.remoteSessionID = remoteSessionID
        binding.agentVersion = agentVersion ?? ""
        binding.negotiatedCapabilities = capabilities
        binding.lastSelectedModel = selectedModel ?? ""
        binding.lastSelectedAgentName = selectedAgentName ?? ""
        binding.lastHandshakeAt = now
        binding.updatedAt = now
        try modelContext.save()
        return binding
    }

    func removeBinding(for sessionID: String, providerReference: ExecutionProviderReference) throws {
        guard let binding = try binding(for: sessionID, providerReference: providerReference) else {
            return
        }
        modelContext.delete(binding)
        try modelContext.save()
    }

    func removeBinding(for sessionID: String, providerID: ConversationExecutionProviderID) throws {
        guard let binding = try binding(for: sessionID, providerID: providerID) else {
            return
        }
        modelContext.delete(binding)
        try modelContext.save()
    }
}