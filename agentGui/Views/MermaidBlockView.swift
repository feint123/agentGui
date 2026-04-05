//
//  MermaidBlockView.swift
//  agentGui
//
//  Created by feint on 2026/2/10.
//

import SwiftUI
import AppKit
import BeautifulMermaid

// MARK: - Mermaid Diagram View

struct MermaidNSView: NSViewRepresentable {
    let source: String
    let theme: DiagramTheme

    func makeNSView(context: Context) -> MermaidView {
        MermaidView(frame: .zero)
    }

    func updateNSView(_ nsView: MermaidView, context: Context) {
        nsView.source = source
        nsView.theme = theme
    }
}

struct MermaidBlockView: View {
    let source: String
    @Environment(\.colorScheme) private var colorScheme
    @SwiftUI.State private var showSource = false
    @SwiftUI.State private var diagramWidth: CGFloat = 600

    private var theme: DiagramTheme {
        colorScheme == .dark ? .zincDark : .zincLight
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Toolbar
            HStack(spacing: 8) {
                Text("mermaid")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                // Width stepper (only shown in diagram mode)
                if !showSource {
                    HStack(spacing: 2) {
                        Button { diagramWidth = max(200, diagramWidth - 100) } label: {
                            Image(systemName: "minus")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        Text("\(Int(diagramWidth))px")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 50)
                        Button { diagramWidth = min(1600, diagramWidth + 100) } label: {
                            Image(systemName: "plus")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                // Toggle source / diagram
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { showSource.toggle() }
                } label: {
                    Label(showSource ? "图表" : "源码",
                          systemImage: showSource ? "chart.xyaxis.line" : "chevron.left.forwardslash.chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial)

            Divider()

            if showSource {
                HorizontalScrollView(showsIndicators: false) {
                    Text(source.trimmingCharacters(in: .newlines))
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                HorizontalScrollView(showsIndicators: true) {
                    MermaidNSView(source: source, theme: theme)
                        .frame(width: diagramWidth, height: 250)
                        .padding(8)
                }
            }
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}
