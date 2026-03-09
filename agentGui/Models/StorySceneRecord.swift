import Foundation
import SwiftData

@Model
final class StorySceneRecord {
    var id: UUID
    var title: String
    var content: String
    var sceneIndex: Int
    var povCharacterName: String
    var locationName: String
    var characterNamesJSON: String
    var summary: String
    var previousSceneId: String
    var timelineEventId: String

    var chapter: StoryChapterRecord?

    init(
        id: UUID = UUID(),
        title: String,
        content: String = "",
        sceneIndex: Int = 0,
        povCharacterName: String = "",
        locationName: String = "",
        characterNamesJSON: String = "[]",
        summary: String = "",
        previousSceneId: String = "",
        timelineEventId: String = ""
    ) {
        self.id = id
        self.title = title
        self.content = content
        self.sceneIndex = sceneIndex
        self.povCharacterName = povCharacterName
        self.locationName = locationName
        self.characterNamesJSON = characterNamesJSON
        self.summary = summary
        self.previousSceneId = previousSceneId
        self.timelineEventId = timelineEventId
    }
}