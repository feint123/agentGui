import Testing
import SwiftData
@testable import agentGui

@MainActor
private func makeMessageSourceResolutionContainer() throws -> ModelContainer {
    let schema = Schema(PersistenceSchema.sharedModelTypes)
    let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, configurations: [configuration])
}

@MainActor
struct ClaudeServiceMessageSourceResolutionTests {

    @Test
    func explicitSourceMessageIDPreventsDuplicateUserMessageCreation() throws {
        let container = try makeMessageSourceResolutionContainer()
        let modelContext = ModelContext(container)
        let session = Session.fixture(title: "Send")
        modelContext.insert(session)

        let originalMessage = Message.userMessage(text: "这个文件由什么用", session: session)
        originalMessage.status = .completed
        let attachment = MessageAttachment(
            filePath: "/tmp/脚本使用总结.md",
            displayName: "脚本使用总结.md",
            fileKind: .other
        )
        attachment.message = originalMessage
        modelContext.insert(originalMessage)
        modelContext.insert(attachment)

        let service = ClaudeService()
        let resolved = service.resolveSourceUserMessageID(
            explicitSourceUserMessageID: originalMessage.id,
            text: "这个文件由什么用\n\nReferenced files:\n- /tmp/脚本使用总结.md",
            session: session,
            modelContext: modelContext
        )

        #expect(resolved == originalMessage.id)
        #expect(session.messages.filter { $0.direction == .user }.count == 1)
    }
}