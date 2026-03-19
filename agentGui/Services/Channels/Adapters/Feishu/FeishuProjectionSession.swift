import Foundation
import SwiftData

@MainActor
final class FeishuProjectionSession: ChannelProjectionSession {
    private let client: any FeishuClient
    private let renderer: FeishuOutboundMessageRenderer
    private let format: FeishuMessageFormat
    private let chatID: String
    private let replyToMessageID: String?
    private let title: String?
    private let sessionID: String?
    private let modelContext: ModelContext?

    private var primaryMessageID: String?
    private var lastProjectedText = ""
    private var closed = false
    private var projectionBinding: SessionProjectionBinding?

    init(
        client: any FeishuClient,
        renderer: FeishuOutboundMessageRenderer,
        format: FeishuMessageFormat,
        chatID: String,
        replyToMessageID: String?,
        title: String?,
        sessionID: String? = nil,
        modelContext: ModelContext? = nil
    ) {
        self.client = client
        self.renderer = renderer
        self.format = format
        self.chatID = chatID
        self.replyToMessageID = replyToMessageID
        self.title = title
        self.sessionID = sessionID
        self.modelContext = modelContext
        self.projectionBinding = Self.loadBinding(
            sessionID: sessionID,
            chatID: chatID,
            modelContext: modelContext
        )
    }

    func ingest(_ event: AgentLoopProjectionEvent) async throws {
        guard !closed else { return }

        switch format {
        case .interactive:
            try await ingestInteractive(event)
        case .text, .post:
            try await ingestAppendOnly(event)
        }
    }

    func close() async {
        closed = true
    }

    private func ingestAppendOnly(_ event: AgentLoopProjectionEvent) async throws {
        switch event {
        case .textSnapshot(let accumulatedText, _, _, _):
            let delta = appendedDelta(from: accumulatedText)
            guard !delta.isEmpty else { return }
            try await sendAppend(text: delta)
            lastProjectedText = accumulatedText

        case .completed(let finalText):
            let delta = appendedDelta(from: finalText)
            if !delta.isEmpty {
                try await sendAppend(text: delta)
            }
            lastProjectedText = finalText
            markTerminalState(kind: .finalize, summary: nil)

        case .failed(let summary):
            if !summary.isEmpty {
                try await sendAppend(text: summary)
            }
            markTerminalState(kind: .fail, summary: summary)

        default:
            break
        }
    }

    private func ingestInteractive(_ event: AgentLoopProjectionEvent) async throws {
        switch event {
        case .textSnapshot(let accumulatedText, _, _, _):
            guard !accumulatedText.isEmpty else { return }
            try await upsertCard(text: accumulatedText)

        case .completed(let finalText):
            if !finalText.isEmpty {
                try await upsertCard(text: finalText)
            }
            markTerminalState(kind: .finalize, summary: nil)

        case .failed(let summary):
            if !summary.isEmpty {
                try await upsertCard(text: summary)
            }
            markTerminalState(kind: .fail, summary: summary)

        default:
            break
        }
    }

    private func sendAppend(text: String) async throws {
        let payload = try renderer.render(text: text, format: format, title: title)
        let isPrimary = primaryMessageID == nil
        let sentMessageID = try await client.sendMessage(
            chatID: chatID,
            payload: payload,
            replyToMessageID: primaryMessageID == nil ? replyToMessageID : nil
        )
        if primaryMessageID == nil {
            primaryMessageID = sentMessageID
        }
        persistDelivery(
            kind: isPrimary ? .primary : .append,
            externalMessageID: sentMessageID,
            summary: text,
            projectedText: isPrimary ? text : nil
        )
    }

    private func upsertCard(text: String) async throws {
        guard text != lastProjectedText || primaryMessageID == nil else { return }
        let payload = try renderer.render(text: text, format: .interactive, title: title)
        if let primaryMessageID {
            try await client.patchMessage(messageID: primaryMessageID, payload: payload)
            persistDelivery(kind: .update, externalMessageID: primaryMessageID, summary: nil, projectedText: text)
        } else {
            primaryMessageID = try await client.sendMessage(
                chatID: chatID,
                payload: payload,
                replyToMessageID: replyToMessageID
            )
            persistDelivery(kind: .primary, externalMessageID: primaryMessageID, summary: nil, projectedText: text)
        }
        lastProjectedText = text
    }

    private func persistDelivery(
        kind: ChannelProjectionDeliveryKind,
        externalMessageID: String?,
        summary: String?,
        projectedText: String?
    ) {
        guard let modelContext else { return }
        let binding = ensureBinding(in: modelContext)
        if let externalMessageID,
           kind == .primary || kind == .append || kind == .update {
            if binding.primaryExternalMessageID == nil {
                binding.primaryExternalMessageID = externalMessageID
            }
            binding.latestExternalMessageID = externalMessageID
        }
        if kind == .fail {
            binding.state = .failed
            binding.lastErrorSummary = summary
        } else if kind == .finalize {
            binding.state = .completed
        } else {
            binding.state = .active
            if projectedText != nil {
                binding.lastErrorSummary = nil
            }
        }
        binding.updatedAt = .now

        let delivery = ChannelProjectionDelivery(
            session: resolvedSession(in: modelContext),
            sessionID: sessionID,
            channelKind: .feishu,
            externalConversationID: chatID,
            externalMessageID: externalMessageID,
            deliveryKind: kind,
            summary: summary
        )
        modelContext.insert(delivery)
        try? modelContext.save()
    }

    private func ensureBinding(in modelContext: ModelContext) -> SessionProjectionBinding {
        if let projectionBinding {
            return projectionBinding
        }
        let binding = SessionProjectionBinding(
            session: resolvedSession(in: modelContext),
            sessionID: sessionID,
            channelKind: .feishu,
            externalConversationID: chatID,
            formatHint: format.rawValue
        )
        modelContext.insert(binding)
        projectionBinding = binding
        try? modelContext.save()
        return binding
    }

    private func resolvedSession(in modelContext: ModelContext) -> Session? {
        guard let sessionID else { return nil }
        return (try? modelContext.fetch(FetchDescriptor<Session>()))?.first(where: { $0.sessionId == sessionID })
    }

    private static func loadBinding(
        sessionID: String?,
        chatID: String,
        modelContext: ModelContext?
    ) -> SessionProjectionBinding? {
        guard let modelContext, let sessionID else { return nil }
        return (try? modelContext.fetch(FetchDescriptor<SessionProjectionBinding>()))?.first {
            $0.sessionID == sessionID && $0.channelKind == .feishu && $0.externalConversationID == chatID
        }
    }

    private func markTerminalState(kind: ChannelProjectionDeliveryKind, summary: String?) {
        persistDelivery(
            kind: kind,
            externalMessageID: primaryMessageID,
            summary: summary,
            projectedText: nil
        )
    }
    private func appendedDelta(from text: String) -> String {
        guard !text.isEmpty else { return "" }
        if text.hasPrefix(lastProjectedText) {
            return String(text.dropFirst(lastProjectedText.count))
        }
        return text
    }
}