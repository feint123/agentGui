import Foundation

struct MemoryDomainProfileRegistry {
    let allProfiles: [MemoryDomainProfile]

    init(allProfiles: [MemoryDomainProfile] = [
        .creativeWriting(),
        .codingTask(),
        .userPreferences()
    ]) {
        self.allProfiles = allProfiles
    }

    func profiles(for request: MemoryRuntimeRequest) -> [MemoryDomainProfile] {
        switch request.taskKind {
        case .creativeWriting:
            return [profile(id: "creative-writing"), profile(id: "user-preferences")].compactMap { $0 }
        case .coding:
            return [profile(id: "coding-task"), profile(id: "user-preferences")].compactMap { $0 }
        case .generalAssistant:
            return [profile(id: "user-preferences")].compactMap { $0 }
        }
    }

    private func profile(id: String) -> MemoryDomainProfile? {
        allProfiles.first(where: { $0.id == id })
    }

    func consolidationRules(for request: MemoryRuntimeRequest) -> [MemoryConsolidationRule] {
        profiles(for: request).flatMap { $0.consolidationRules() }
    }
}