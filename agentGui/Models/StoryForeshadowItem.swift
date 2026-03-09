import Foundation
import SwiftData

@Model
final class StoryForeshadowItem {
    var id: UUID
    var tag: String
    var introducedInChapter: Int
    var detail: String
    var relatedEventIdsJSON: String
    var status: String
    var resolvedInChapter: Int

    var project: WritingProject?

    init(
        id: UUID = UUID(),
        tag: String,
        introducedInChapter: Int = 0,
        detail: String = "",
        relatedEventIdsJSON: String = "[]",
        status: String = "open",
        resolvedInChapter: Int = 0
    ) {
        self.id = id
        self.tag = tag
        self.introducedInChapter = introducedInChapter
        self.detail = detail
        self.relatedEventIdsJSON = relatedEventIdsJSON
        self.status = status
        self.resolvedInChapter = resolvedInChapter
    }
}