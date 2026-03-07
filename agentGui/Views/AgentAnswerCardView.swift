//
//  AgentAnswerCardView.swift
//  agentGui
//
//  Primary answer card for agent messages.
//  Presents the answer text in a stable, clean container — keeps the reading focus
//  on the content rather than the execution machinery.
//

import SwiftUI

/// The main reading container for an agent reply.
/// Receives pre-computed display text and renders it inside a subtle card.
struct AgentAnswerCardView: View {
    /// The consolidated answer text to display (may be empty while streaming).
    let text: String
    var isStreaming: Bool = false
    var isPending: Bool = false

    @ViewBuilder
    var body: some View {
        if !text.isEmpty {
            MarkdownMessageView(text: text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(cardBorder)
        } else if isStreaming && isPending {
            HStack(spacing: 7) {
                ProgressView().scaleEffect(0.6)
                Text("正在思考…")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(cardBorder)
        }
    }

    private var cardBackground: some ShapeStyle {
        Color.primary.opacity(0.025)
    }

    private var cardBorder: some View {
        RoundedRectangle(cornerRadius: 12)
            .stroke(Color.primary.opacity(0.07), lineWidth: 1)
    }
}
