import Foundation

struct MemoryConsolidationRule: Equatable, Sendable, Identifiable {
    var id: String
    var sourceLayers: Set<MemoryLayer>
    var targetLayer: MemoryLayer
    var targetKind: MemoryKind
    var requiresVerified: Bool
    var minimumConfidence: Double

    init(
        id: String,
        sourceLayers: Set<MemoryLayer>,
        targetLayer: MemoryLayer,
        targetKind: MemoryKind,
        requiresVerified: Bool = false,
        minimumConfidence: Double = 0.0
    ) {
        self.id = id
        self.sourceLayers = sourceLayers
        self.targetLayer = targetLayer
        self.targetKind = targetKind
        self.requiresVerified = requiresVerified
        self.minimumConfidence = minimumConfidence
    }
}