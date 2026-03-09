import Foundation
import SwiftData

@Model
final class StoryLocationProfile {
    var id: UUID
    var name: String
    var summary: String
    var traitsJSON: String
    var relatedRulesJSON: String
    var occupantNamesJSON: String

    var project: WritingProject?

    init(
        id: UUID = UUID(),
        name: String,
        summary: String = "",
        traitsJSON: String = "[]",
        relatedRulesJSON: String = "[]",
        occupantNamesJSON: String = "[]"
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.traitsJSON = traitsJSON
        self.relatedRulesJSON = relatedRulesJSON
        self.occupantNamesJSON = occupantNamesJSON
    }
}