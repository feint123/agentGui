import Foundation
import Testing
@testable import agentGui

struct WorkspaceTreeDropCoordinatorTests {

    @Test func rejectsDroppingDirectoryIntoItsOwnDescendant() {
        let sourcesURL = URL(fileURLWithPath: "/tmp/ws/Sources")
        let childURL = sourcesURL.appending(path: "Feature")
        let destination = FileNode(id: childURL, name: "Feature", isDirectory: true, children: [])

        let plan = WorkspaceTreeDropCoordinator().proposal(
            for: [sourcesURL],
            destination: destination,
            rootDirectory: URL(fileURLWithPath: "/tmp/ws")
        )

        #expect(plan == nil)
    }

    @Test func ignoresNoOpMoveBackIntoSameParentDirectory() {
        let fileURL = URL(fileURLWithPath: "/tmp/ws/Docs/Readme.md")
        let destination = FileNode(id: URL(fileURLWithPath: "/tmp/ws/Docs"), name: "Docs", isDirectory: true, children: [])

        let plan = WorkspaceTreeDropCoordinator().proposal(
            for: [fileURL],
            destination: destination,
            rootDirectory: URL(fileURLWithPath: "/tmp/ws")
        )

        #expect(plan == nil)
    }

    @Test func collapsesNestedSelectionsAndUsesDestinationParentForFiles() {
        let directoryURL = URL(fileURLWithPath: "/tmp/ws/Sources/Feature")
        let nestedFileURL = directoryURL.appending(path: "View.swift")
        let destinationFileURL = URL(fileURLWithPath: "/tmp/ws/Archive/Marker.txt")
        let destination = FileNode(id: destinationFileURL, name: "Marker.txt", isDirectory: false, children: nil)

        let plan = WorkspaceTreeDropCoordinator().proposal(
            for: [directoryURL, nestedFileURL],
            destination: destination,
            rootDirectory: URL(fileURLWithPath: "/tmp/ws")
        )

        #expect(plan?.draggedURLs == [directoryURL.standardizedFileURL])
        #expect(plan?.destinationDirectory == destinationFileURL.deletingLastPathComponent().standardizedFileURL)
    }

    @Test func usesWorkspaceRootWhenDroppingOntoOutlineBackground() {
        let fileURL = URL(fileURLWithPath: "/tmp/ws/Docs/Readme.md")
        let rootURL = URL(fileURLWithPath: "/tmp/ws")

        let plan = WorkspaceTreeDropCoordinator().proposal(
            for: [fileURL],
            destination: nil,
            rootDirectory: rootURL
        )

        #expect(plan?.draggedURLs == [fileURL.standardizedFileURL])
        #expect(plan?.destinationDirectory == rootURL.standardizedFileURL)
    }

    @Test func rejectsRootLevelDropWithoutWorkspaceRoot() {
        let fileURL = URL(fileURLWithPath: "/tmp/ws/Docs/Readme.md")

        let plan = WorkspaceTreeDropCoordinator().proposal(
            for: [fileURL],
            destination: nil,
            rootDirectory: nil
        )

        #expect(plan == nil)
    }
}
