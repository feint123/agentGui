import Foundation
import SwiftData

@Model
final class StoryWorldRule {
    var id: UUID
    var category: String
    var title: String
    var detail: String
    var scope: String
    var exceptionsJSON: String
    var establishedInChapter: Int
    var relatedEntitiesJSON: String
    var mutablePolicy: String

    var project: WritingProject?

    init(
        id: UUID = UUID(),
        category: String = "",
        title: String,
        detail: String = "",
        scope: String = "",
        exceptionsJSON: String = "[]",
        establishedInChapter: Int = 0,
        relatedEntitiesJSON: String = "[]",
        mutablePolicy: String = "immutable"
    ) {
        self.id = id
        self.category = category
        self.title = title
        self.detail = detail
        self.scope = scope
        self.exceptionsJSON = exceptionsJSON
        self.establishedInChapter = establishedInChapter
        self.relatedEntitiesJSON = relatedEntitiesJSON
        self.mutablePolicy = mutablePolicy
    }
}