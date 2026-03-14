import Foundation

struct MemoryInvalidationService {
    func recordsToInvalidate(from outcome: MemoryRuntimeOutcome) -> [String] {
        outcome.records
            .filter { $0.verificationStatus == .failed }
            .map(\.id)
    }
}