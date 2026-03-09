import Foundation
import SwiftData

@Model
final class StoryContinuityIssue {
    var id: UUID
    var issueKind: String
    var severity: String
    var chapterNumber: Int
    var sceneIndex: Int
    var detail: String
    var resolutionStatus: String

    var project: WritingProject?

    init(
        id: UUID = UUID(),
        issueKind: String,
        severity: String = "warning",
        chapterNumber: Int = 0,
        sceneIndex: Int = 0,
        detail: String = "",
        resolutionStatus: String = "open"
    ) {
        self.id = id
        self.issueKind = issueKind
        self.severity = severity
        self.chapterNumber = chapterNumber
        self.sceneIndex = sceneIndex
        self.detail = detail
        self.resolutionStatus = resolutionStatus
    }
}