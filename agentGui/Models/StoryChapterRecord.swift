import Foundation
import SwiftData

@Model
final class StoryChapterRecord {
    var id: UUID
    var number: Int
    var title: String
    var outline: String
    var summary: String
    var toneDirective: String
    var isLocked: Bool

    @Relationship(deleteRule: .cascade)
    var scenes: [StorySceneRecord] = []

    var project: WritingProject?

    init(
        id: UUID = UUID(),
        number: Int,
        title: String,
        outline: String = "",
        summary: String = "",
        toneDirective: String = "",
        isLocked: Bool = false
    ) {
        self.id = id
        self.number = number
        self.title = title
        self.outline = outline
        self.summary = summary
        self.toneDirective = toneDirective
        self.isLocked = isLocked
    }
}