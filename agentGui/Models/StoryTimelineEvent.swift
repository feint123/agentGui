import Foundation
import SwiftData

@Model
final class StoryTimelineEvent {
    var id: UUID
    var chapterNumber: Int
    var sceneIndex: Int
    var title: String
    var summary: String
    var participantNamesJSON: String
    var locationName: String
    var timeMarker: String
    var eventType: String
    var foreshadowTagsJSON: String
    var isResolved: Bool
    var supersededByEventId: String

    var project: WritingProject?

    init(
        id: UUID = UUID(),
        chapterNumber: Int = 0,
        sceneIndex: Int = 0,
        title: String,
        summary: String = "",
        participantNamesJSON: String = "[]",
        locationName: String = "",
        timeMarker: String = "",
        eventType: String = "",
        foreshadowTagsJSON: String = "[]",
        isResolved: Bool = false,
        supersededByEventId: String = ""
    ) {
        self.id = id
        self.chapterNumber = chapterNumber
        self.sceneIndex = sceneIndex
        self.title = title
        self.summary = summary
        self.participantNamesJSON = participantNamesJSON
        self.locationName = locationName
        self.timeMarker = timeMarker
        self.eventType = eventType
        self.foreshadowTagsJSON = foreshadowTagsJSON
        self.isResolved = isResolved
        self.supersededByEventId = supersededByEventId
    }
}