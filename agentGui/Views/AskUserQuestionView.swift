//
//  AskUserQuestionView.swift
//  agentGui
//

import SwiftUI

/// Sheet presented when Claude calls ask_user_question.
/// Renders each question with its option list and a Submit button.
struct AskUserQuestionView: View {

    let request: AskUserQuestionRequest

    // Per-question selection state: index → Set of selected labels
    @State private var selections: [Set<String>]

    @Environment(\.dismiss) private var dismiss

    init(request: AskUserQuestionRequest) {
        self.request = request
        _selections = State(initialValue: request.questions.map { _ in [] })
    }

    // Submit is enabled only when every question has at least one selection
    private var canSubmit: Bool {
        selections.allSatisfy { !$0.isEmpty }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header bar
            HStack {
                Text("Claude 需要您回答")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            // Questions
            ScrollView {
                VStack(spacing: 20) {
                    ForEach(request.questions.indices, id: \.self) { qi in
                        questionSection(index: qi)
                    }
                }
                .padding(20)
            }

            Divider()

            // Footer buttons
            HStack {
                Button("取消") {
                    request.cancel()
                    dismiss()
                }
                .keyboardShortcut(.escape, modifiers: [])

                Spacer()

                Button("提交") {
                    let result = selections.map { Array($0) }
                    request.submit(selections: result)
                    dismiss()
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canSubmit)
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(minWidth: 480, minHeight: 300)
    }

    @ViewBuilder
    private func questionSection(index qi: Int) -> some View {
        let question = request.questions[qi]
        VStack(alignment: .leading, spacing: 10) {
            // Header
            if !question.header.isEmpty {
                Text(question.header)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
            }

            // Question text
            Text(question.question)
                .font(.body)
                .fontWeight(.medium)

            if question.multiSelect {
                Text("可多选")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            // Options
            VStack(spacing: 6) {
                ForEach(question.options, id: \.label) { option in
                    optionRow(option: option, questionIndex: qi, multiSelect: question.multiSelect)
                }
            }
        }
        .padding(14)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func optionRow(option: AskUserQuestionOption, questionIndex qi: Int, multiSelect: Bool) -> some View {
        let isSelected = selections[qi].contains(option.label)

        Button {
            if multiSelect {
                if isSelected {
                    selections[qi].remove(option.label)
                } else {
                    selections[qi].insert(option.label)
                }
            } else {
                selections[qi] = [option.label]
            }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                // Selection indicator
                ZStack {
                    if multiSelect {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(isSelected ? Color.accentColor : Color.clear)
                            .frame(width: 18, height: 18)
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.4), lineWidth: 1.5)
                            .frame(width: 18, height: 18)
                        if isSelected {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    } else {
                        Circle()
                            .fill(isSelected ? Color.accentColor : Color.clear)
                            .frame(width: 18, height: 18)
                        Circle()
                            .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.4), lineWidth: 1.5)
                            .frame(width: 18, height: 18)
                        if isSelected {
                            Circle()
                                .fill(.primary)
                                .frame(width: 8, height: 8)
                        }
                    }
                }
                .frame(width: 18, height: 18)
                .padding(.top, 2)

                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label)
                        .font(.callout)
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)
                    if !option.description.isEmpty {
                        Text(option.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.accentColor.opacity(0.08) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.accentColor.opacity(0.3) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}
