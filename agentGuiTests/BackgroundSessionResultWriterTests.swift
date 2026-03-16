import Foundation
import SwiftData
import Testing
@testable import agentGui

@MainActor
struct BackgroundSessionResultWriterTests {
    @Test func writerAppendsSystemAndAgentMessages() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Session.self, Message.self, configurations: configuration)
        let context = ModelContext(container)
        let session = Session.fixture(sessionId: "session-1", title: "Background")
        context.insert(session)
        try context.save()

        let writer = BackgroundSessionResultWriter(persistenceCoordinator: .shared)
        let task = BackgroundAgentTask.fixture(title: "日报", sessionId: session.sessionId)

        let written = try writer.writeSuccessResult(
            task: task,
            output: "后台执行完成",
            summary: "success",
            modelContext: context
        )

        let messages = try context.fetch(FetchDescriptor<Message>()).sorted { $0.sequence < $1.sequence }
        #expect(messages.count == 2)
        #expect(messages.first?.direction == .system)
        #expect(messages.last?.direction == .agent)
        #expect(messages.last?.textContent == "后台执行完成")
        #expect(written?.textContent == "后台执行完成")
    }

    @Test func writerSupportsSummaryOnlyDelivery() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Session.self, Message.self, configurations: configuration)
        let context = ModelContext(container)
        let session = Session.fixture(sessionId: "session-1", title: "Background")
        context.insert(session)
        try context.save()

        let writer = BackgroundSessionResultWriter(persistenceCoordinator: .shared)
        let task = BackgroundAgentTask.fixture(title: "日报", sessionId: session.sessionId)
        var executionPolicy = task.executionPolicy
        executionPolicy.resultDeliveryMode = .summaryOnly
        executionPolicy.appendUserVisibleMessage = true
        task.executionPolicy = executionPolicy

        let written = try writer.writeSuccessResult(
            task: task,
            output: "后台执行完成",
            summary: "success",
            modelContext: context
        )

        let messages = try context.fetch(FetchDescriptor<Message>()).sorted { $0.sequence < $1.sequence }
        #expect(messages.count == 1)
        #expect(messages.first?.direction == .system)
        #expect(messages.first?.textContent == "后台任务“日报”已完成：success")
        #expect(written?.direction == .system)
    }

    @Test func writerSkipsVisibleMessagesWhenAppendIsDisabled() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Session.self, Message.self, configurations: configuration)
        let context = ModelContext(container)
        let session = Session.fixture(sessionId: "session-1", title: "Background")
        context.insert(session)
        try context.save()

        let writer = BackgroundSessionResultWriter(persistenceCoordinator: .shared)
        let task = BackgroundAgentTask.fixture(title: "日报", sessionId: session.sessionId)
        var executionPolicy = task.executionPolicy
        executionPolicy.appendUserVisibleMessage = false
        task.executionPolicy = executionPolicy

        let written = try writer.writeSuccessResult(
            task: task,
            output: "后台执行完成",
            summary: "success",
            modelContext: context
        )

        let messages = try context.fetch(FetchDescriptor<Message>())
        #expect(messages.isEmpty)
        #expect(written == nil)
    }
}