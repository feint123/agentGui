import Testing
import Foundation
@testable import agentGui

struct MessageAttachmentSnapshotBuilderTests {

    @Test
    func fingerprintDiffersWhenAttachmentAdded() {
        let base = MessageRowBuildInput.fixture(
            id: UUID(),
            structuredAttachments: []
        )
        let withAttachment = MessageRowBuildInput.fixture(
            id: base.id,
            structuredAttachments: [
                .init(id: UUID(), filePath: "/src/A.swift",
                      displayName: "A.swift", fileKindRaw: "sourceCode",
                      statusRaw: "valid")
            ]
        )
        let fp1 = MessageRowSemanticFingerprint(base)
        let fp2 = MessageRowSemanticFingerprint(withAttachment)
        #expect(fp1 != fp2)
    }

    @Test
    func fingerprintEqualWhenAttachmentUnchanged() {
        let attachmentID = UUID()
        let sharedTimestamp = Date(timeIntervalSince1970: 1_000_000)
        let entry = AttachmentSnapshotEntry(
            id: attachmentID, filePath: "/src/A.swift",
            displayName: "A.swift", fileKindRaw: "sourceCode", statusRaw: "valid"
        )
        let a = MessageRowBuildInput.fixture(id: UUID(), timestamp: sharedTimestamp, structuredAttachments: [entry])
        let b = MessageRowBuildInput.fixture(id: a.id, timestamp: sharedTimestamp, structuredAttachments: [entry])
        #expect(MessageRowSemanticFingerprint(a) == MessageRowSemanticFingerprint(b))
    }

    @Test
    func snapshotFromStructuredDataIgnoresTextParsing() {
        let entry = AttachmentSnapshotEntry(
            id: UUID(), filePath: "/src/Main.swift",
            displayName: "Main.swift", fileKindRaw: "sourceCode", statusRaw: "valid"
        )
        let input = MessageRowBuildInput.fixture(
            direction: .user,
            // textContent 故意带旧格式，验证结构化优先
            textContent: "hello\n\nReferenced files:\n- /legacy/Old.swift",
            structuredAttachments: [entry]
        )
        let snap = MessageRowSnapshot.make(for: input, workspaceRoot: "/ws")
        // 结构化来源：只有 Main.swift
        #expect(snap.user?.presentation.others.first?.filePath == "/src/Main.swift")
        #expect(snap.user?.presentation.others.contains(where: { $0.filePath == "/legacy/Old.swift" }) == false)
    }

    @Test
    func snapshotFallsBackToTextParsingWhenNoStructuredAttachments() {
        let input = MessageRowBuildInput.fixture(
            direction: .user,
            textContent: "hello\n\nReferenced files:\n- /legacy/Old.swift",
            structuredAttachments: []
        )
        let snap = MessageRowSnapshot.make(for: input, workspaceRoot: "/ws")
        #expect(snap.user?.presentation.others.first?.filePath == "/legacy/Old.swift")
    }

    @Test
    func agentSnapshotReadsStructuredAttachments() {
        let entry = AttachmentSnapshotEntry(
            id: UUID(), filePath: "/img/chart.png",
            displayName: "chart.png", fileKindRaw: "image", statusRaw: "valid"
        )
        let input = MessageRowBuildInput.fixture(
            direction: .agent,
            structuredAttachments: [entry]
        )
        let snap = MessageRowSnapshot.make(for: input, workspaceRoot: "/ws")
        #expect(snap.agent?.attachments.images == ["/img/chart.png"])
    }

    // === 后向兼容场景（模拟旧消息） ===

    @Test
    func legacyUserMessageWithNoAttachmentsUsesTextParsing() {
        let input = MessageRowBuildInput.fixture(
            direction: .user,
            textContent: "分析一下\n\nReferenced files:\n- /old/File.swift\n- /old/Lib.swift",
            structuredAttachments: []
        )
        let snap = MessageRowSnapshot.make(for: input, workspaceRoot: "/ws")
        #expect(snap.user?.presentation.others.count == 2)
        #expect(snap.user?.presentation.others.contains(where: { $0.filePath == "/old/File.swift" }) == true)
    }

    @Test
    func legacyAgentMessageWithNoAttachmentsUsesTextParsing() {
        let input = MessageRowBuildInput.fixture(
            direction: .agent,
            textContent: "done\n\nReferenced files:\n- /out/result.png",
            structuredAttachments: []
        )
        let snap = MessageRowSnapshot.make(for: input, workspaceRoot: "/ws")
        #expect(snap.agent?.attachments.images == ["/out/result.png"])
    }

    @Test
    func emptyTextContentProducesEmptySnapshot() {
        let input = MessageRowBuildInput.fixture(direction: .user, textContent: nil, structuredAttachments: [])
        let snap = MessageRowSnapshot.make(for: input, workspaceRoot: "/ws")
        #expect(snap.user?.presentation.others.isEmpty == true)
    }
}
