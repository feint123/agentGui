import Foundation
import SwiftData

@Model
final class StoryCharacterProfile {
    var id: UUID
    var name: String
    var summary: String
    var traitsJSON: String
    var goalsJSON: String
    var speechStyle: String
    var relationshipMapJSON: String
    var arcStage: String
    var lastSeenChapter: Int
    var lastKnownLocation: String

    var project: WritingProject?

    init(
        id: UUID = UUID(),
        name: String,
        summary: String = "",
        traitsJSON: String = "[]",
        goalsJSON: String = "[]",
        speechStyle: String = "",
        relationshipMapJSON: String = "{}",
        arcStage: String = "",
        lastSeenChapter: Int = 0,
        lastKnownLocation: String = ""
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.traitsJSON = traitsJSON
        self.goalsJSON = goalsJSON
        self.speechStyle = speechStyle
        self.relationshipMapJSON = relationshipMapJSON
        self.arcStage = arcStage
        self.lastSeenChapter = lastSeenChapter
        self.lastKnownLocation = lastKnownLocation
    }
}