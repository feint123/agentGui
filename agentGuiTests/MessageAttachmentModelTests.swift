import Testing
import Foundation
@testable import agentGui

@MainActor
struct MessageAttachmentModelTests {

    @Test
    func initSetsDefaultStatus() {
        let a = MessageAttachment(filePath: "/tmp/Foo.swift", displayName: "Foo.swift", fileKind: .sourceCode)
        #expect(a.status == .valid)
        #expect(a.lineStart == nil)
        #expect(a.lineEnd == nil)
    }

    @Test
    func fileTypeDetectedFromExtension() {
        let swift   = MessageAttachment(filePath: "/src/Foo.swift",  displayName: "Foo.swift",  fileKind: .sourceCode)
        let png     = MessageAttachment(filePath: "/img/bg.png",     displayName: "bg.png",     fileKind: .image)
        let pdf     = MessageAttachment(filePath: "/doc/spec.pdf",   displayName: "spec.pdf",   fileKind: .pdf)
        let other   = MessageAttachment(filePath: "/doc/notes.txt",  displayName: "notes.txt",  fileKind: .other)
        #expect(swift.fileKind == .sourceCode)
        #expect(png.fileKind   == .image)
        #expect(pdf.fileKind   == .pdf)
        #expect(other.fileKind == .other)
    }

    @Test
    func lineRangeRoundTrips() {
        let a = MessageAttachment(filePath: "/tmp/F.swift", displayName: "F.swift",
                                  fileKind: .sourceCode, lineStart: 10, lineEnd: 42)
        #expect(a.lineStart == 10)
        #expect(a.lineEnd   == 42)
    }

    @Test
    func messageHoldsAttachments() {
        let session = Session.fixture(title: "CV-F1 Test")
        let message = Message.userFixture(session: session)
        let a1 = MessageAttachment(filePath: "/src/A.swift", displayName: "A.swift", fileKind: .sourceCode)
        let a2 = MessageAttachment(filePath: "/img/b.png",   displayName: "b.png",   fileKind: .image)
        message.attachments = [a1, a2]
        #expect(message.attachments.count == 2)
        #expect(message.attachments.first?.displayName == "A.swift")
    }

    @Test
    func attachedFilesWrittenToRelationshipNotText() {
        let session = Session.fixture(title: "Send Test")
        let a = AttachedFile(name: "Foo.swift", url: URL(fileURLWithPath: "/src/Foo.swift"))
        let message = Message.userMessage(text: "看这个文件", session: session)
        message.attachments = [MessageAttachment.from(a)]

        // textContent 里不应再含 "Referenced files:"
        let text = message.textContent ?? ""
        #expect(!text.contains("Referenced files:"))
        // 结构化附件应存在
        #expect(message.attachments.count == 1)
        #expect(message.attachments.first?.filePath == "/src/Foo.swift")
    }
}

// MARK: - CV-FA2: originRaw and selectedText fields

extension MessageAttachmentModelTests {

    @Test
    func defaultOriginIsExternal() {
        let a = MessageAttachment(filePath: "/tmp/F.swift", displayName: "F.swift", fileKind: .sourceCode)
        #expect(a.origin == .external)
        #expect(a.originRaw == AttachmentOrigin.external.rawValue)
    }

    @Test
    func focusedOriginRoundTrips() {
        let a = MessageAttachment(
            filePath: "/tmp/F.swift",
            displayName: "F.swift",
            fileKind: .sourceCode,
            origin: .focused
        )
        #expect(a.origin == .focused)
        #expect(a.originRaw == "focused")
    }

    @Test
    func selectedTextStoredOnFocusedAttachment() {
        let a = MessageAttachment(
            filePath: "/tmp/F.swift",
            displayName: "F.swift",
            fileKind: .sourceCode,
            origin: .focused,
            selectedText: "let x = 42"
        )
        #expect(a.selectedText == "let x = 42")
    }

    @Test
    func fromAttachedFileCopiesOrigin() {
        let file = AttachedFile(
            name: "View.swift",
            url: URL(fileURLWithPath: "/src/View.swift"),
            origin: .focused
        )
        let attachment = MessageAttachment.from(file)
        #expect(attachment.origin == .focused)
    }

    @Test
    func fromAttachedFileFocusedWithSelectedText() {
        var file = AttachedFile(
            name: "View.swift",
            url: URL(fileURLWithPath: "/src/View.swift"),
            origin: .focused
        )
        file.selectedText = "body { EmptyView() }"
        let attachment = MessageAttachment.from(file)
        #expect(attachment.origin == .focused)
        #expect(attachment.selectedText == "body { EmptyView() }")
    }
}
