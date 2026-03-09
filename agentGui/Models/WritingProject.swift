import Foundation
import SwiftData

@Model
final class WritingProject {
    var id: UUID
    var title: String
    var synopsis: String
    var createdAt: Date
    var updatedAt: Date
    var isArchived: Bool

    @Relationship(deleteRule: .cascade)
    var characters: [StoryCharacterProfile] = []

    @Relationship(deleteRule: .cascade)
    var worldRules: [StoryWorldRule] = []

    @Relationship(deleteRule: .cascade)
    var locations: [StoryLocationProfile] = []

    @Relationship(deleteRule: .cascade)
    var chapters: [StoryChapterRecord] = []

    @Relationship(deleteRule: .cascade)
    var timelineEvents: [StoryTimelineEvent] = []

    @Relationship(deleteRule: .cascade)
    var foreshadowItems: [StoryForeshadowItem] = []

    @Relationship(deleteRule: .cascade)
    var continuityIssues: [StoryContinuityIssue] = []

    var styleProfile: StoryStyleProfile?

    init(
        id: UUID = UUID(),
        title: String,
        synopsis: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        isArchived: Bool = false
    ) {
        self.id = id
        self.title = title
        self.synopsis = synopsis
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isArchived = isArchived
    }
}