import Foundation
import Observation

@MainActor
@Observable
final class ChatExecutionProviderAvailabilityModel {
    @ObservationIgnored private let probe: @Sendable (String, String) async -> ACPCLIAvailabilityStatus

    private(set) var statusesByProviderKey: [String: ACPCLIAvailabilityStatus] = [:]
    private(set) var refreshingProviderKeys: Set<String> = []

    init(
        probe: @escaping @Sendable (String, String) async -> ACPCLIAvailabilityStatus = ChatExecutionProviderAvailabilityModel.defaultProbe
    ) {
        self.probe = probe
    }

    func refreshStatus(
        for providerReference: ExecutionProviderReference,
        executablePath: String,
        displayName: String
    ) async {
        guard let providerKey = providerKey(for: providerReference) else {
            return
        }

        setRefreshing(true, providerKey: providerKey)
        defer { setRefreshing(false, providerKey: providerKey) }

        let status = await probe(executablePath, displayName)
        if statusesByProviderKey[providerKey] != status {
            statusesByProviderKey[providerKey] = status
        }
    }

    func status(for providerReference: ExecutionProviderReference) -> ACPCLIAvailabilityStatus? {
        switch providerReference {
        case .builtIn:
            return ACPCLIAvailabilityStatus(kind: .available, version: nil, displayName: "内置 Agent")
        case .externalACP:
            guard let providerKey = providerKey(for: providerReference) else {
                return nil
            }
            return statusesByProviderKey[providerKey] ?? .unknown
        }
    }

    func isRefreshing(for providerReference: ExecutionProviderReference) -> Bool {
        guard let providerKey = providerKey(for: providerReference) else {
            return false
        }
        return refreshingProviderKeys.contains(providerKey)
    }

    private func providerKey(for providerReference: ExecutionProviderReference) -> String? {
        switch providerReference {
        case .builtIn:
            return nil
        case let .externalACP(profileID):
            return profileID.uuidString.lowercased()
        }
    }

    private func setRefreshing(_ isRefreshing: Bool, providerKey: String) {
        if isRefreshing {
            refreshingProviderKeys.insert(providerKey)
        } else {
            refreshingProviderKeys.remove(providerKey)
        }
    }

    private static func defaultProbe(executablePath: String, displayName: String) async -> ACPCLIAvailabilityStatus {
        do {
            return try await ACPCLIAvailabilityService().checkStatus(
                executablePath: executablePath,
                displayName: displayName
            )
        } catch {
            return ACPCLIAvailabilityStatus(kind: .failed(error.localizedDescription), version: nil)
        }
    }
}