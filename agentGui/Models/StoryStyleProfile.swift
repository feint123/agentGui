import Foundation
import SwiftData

@Model
final class StoryStyleProfile {
    var id: UUID
    var authorPreferences: String
    var narrativeVoice: String
    var sentenceLengthMean: Double
    var dialogueRatio: Double
    var imageryDensity: Double
    var samplePassagesJSON: String
    var antiPatternsJSON: String

    var project: WritingProject?

    init(
        id: UUID = UUID(),
        authorPreferences: String = "",
        narrativeVoice: String = "",
        sentenceLengthMean: Double = 0,
        dialogueRatio: Double = 0,
        imageryDensity: Double = 0,
        samplePassagesJSON: String = "[]",
        antiPatternsJSON: String = "[]"
    ) {
        self.id = id
        self.authorPreferences = authorPreferences
        self.narrativeVoice = narrativeVoice
        self.sentenceLengthMean = sentenceLengthMean
        self.dialogueRatio = dialogueRatio
        self.imageryDensity = imageryDensity
        self.samplePassagesJSON = samplePassagesJSON
        self.antiPatternsJSON = antiPatternsJSON
    }
}