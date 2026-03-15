import Foundation

struct RMSMemoryRuntimeContext: Equatable, Sendable {
    var profiles: [String]
    var records: [MemoryRecord]
    var writePolicy: MemoryWritePolicy
    var warnings: [String]
    var renderedPrompt: String

    init(
        profiles: [String],
        records: [MemoryRecord],
        writePolicy: MemoryWritePolicy = .readMostly,
        warnings: [String] = [],
        renderedPrompt: String = ""
    ) {
        self.profiles = profiles
        self.records = records
        self.writePolicy = writePolicy
        self.warnings = warnings
        self.renderedPrompt = renderedPrompt
    }
}