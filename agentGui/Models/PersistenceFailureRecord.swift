import Foundation
import SwiftData

@Model
final class PersistenceFailureRecord {
    var domainRaw: String
    var categoryRaw: String
    var userMessage: String
    var technicalMessage: String
    var metadataJSON: String
    var createdAt: Date
    var isCritical: Bool

    init(
        domain: PersistenceCoordinator.SaveDomain,
        category: PersistenceCoordinator.FailureCategory,
        userMessage: String,
        technicalMessage: String,
        metadata: [String: String] = [:],
        isCritical: Bool
    ) {
        self.domainRaw = domain.rawValue
        self.categoryRaw = category.rawValue
        self.userMessage = userMessage
        self.technicalMessage = technicalMessage
        self.createdAt = Date()
        self.isCritical = isCritical
        self.metadataJSON = (try? String(data: JSONEncoder().encode(metadata), encoding: .utf8)) ?? "{}"
    }
}

extension PersistenceFailureRecord {
    var domain: PersistenceCoordinator.SaveDomain {
        PersistenceCoordinator.SaveDomain(rawValue: domainRaw) ?? .settings
    }

    var category: PersistenceCoordinator.FailureCategory {
        PersistenceCoordinator.FailureCategory(rawValue: categoryRaw) ?? .unknown
    }

    var metadata: [String: String] {
        guard let data = metadataJSON.data(using: .utf8) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }
}