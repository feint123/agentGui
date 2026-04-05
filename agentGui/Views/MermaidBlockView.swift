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

// MARK: - Render State

enum MermaidRenderState {
    case loading
    case success(NSImage, CGFloat)   // image, aspectRatio (width/height)
    case failure(String)             // error description
}

extension MermaidRenderState: Equatable {
    static func == (lhs: MermaidRenderState, rhs: MermaidRenderState) -> Bool {
        switch (lhs, rhs) {
        case (.loading, .loading):
            return true
        case (.success(_, let la), .success(_, let ra)):
            // Compare by aspect ratio only; sufficient for preventing spurious re-renders
            return abs(la - ra) < 0.001
        case (.failure(let lm), .failure(let rm)):
            return lm == rm
        default:
            return false
        }
    }
}

// MARK: - Async Renderer

actor MermaidAsyncRenderer {
    /// Renders Mermaid source to an image on the actor's executor (off main thread).
    /// - Returns: `(image, aspectRatio)` where aspectRatio = width / height
    /// - Throws: Any error thrown by MermaidRenderer (parse/layout errors)
    func render(
        source: String,
        theme: DiagramTheme,
        scale: CGFloat = 2.0
    ) async throws -> (NSImage, CGFloat) {
        guard let image = try MermaidRenderer.renderImage(
            source: source,
            theme: theme,
            scale: scale
        ) else {
            throw MermaidRenderError.emptyResult
        }
        let size = image.size
        guard size.width > 0, size.height > 0 else {
            throw MermaidRenderError.invalidSize(size)
        }
        let aspectRatio = size.width / size.height
        return (image, aspectRatio)
    }
}

enum MermaidRenderError: Error, LocalizedError {
    case emptyResult
    case invalidSize(CGSize)

    var errorDescription: String? {
        switch self {
        case .emptyResult:
            return "图表渲染返回空结果"
        case .invalidSize(let size):
            return "图表尺寸无效：\(size.width) × \(size.height)"
        }
    }
}

struct MermaidBlockView: View {
    let source: String
    @Environment(\.colorScheme) private var colorScheme
    @SwiftUI.State private var showSource = false
    @SwiftUI.State private var diagramWidth: CGFloat = 600
    @SwiftUI.State private var renderState: MermaidRenderState = .loading
    @SwiftUI.State private var renderer = MermaidAsyncRenderer()

    private var theme: DiagramTheme {
        colorScheme == .dark ? .zincDark : .zincLight
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            toolbar
            Divider()
            content
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .task(id: source + (colorScheme == .dark ? "dark" : "light")) {
            await triggerRender()
        }
    }

    // MARK: - Sub-views

    @ViewBuilder
    private var toolbar: some View {
        HStack(spacing: 8) {
            Text("mermaid")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if !showSource {
                widthStepper
            }
            sourceToggleButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
    }

    private var widthStepper: some View {
        HStack(spacing: 2) {
            Button { diagramWidth = max(200, diagramWidth - 100) } label: {
                Image(systemName: "minus").font(.caption)
            }
            .buttonStyle(.plain)
            Text("\(Int(diagramWidth))px")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(minWidth: 50)
            Button { diagramWidth = min(1600, diagramWidth + 100) } label: {
                Image(systemName: "plus").font(.caption)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.primary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    private var sourceToggleButton: some View {
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

    @ViewBuilder
    private var content: some View {
        if showSource {
            sourceView
        } else {
            diagramView
        }
    }

    private var sourceView: some View {
        HorizontalScrollView(showsIndicators: false) {
            Text(source.trimmingCharacters(in: .newlines))
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var diagramView: some View {
        switch renderState {
        case .loading:
            SkeletonBlock(height: 200)
                .padding(8)

        case .success(let image, let aspectRatio):
            let height = diagramWidth / aspectRatio
            HorizontalScrollView(showsIndicators: true) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: diagramWidth, height: height)
                    .padding(8)
            }

        case .failure:
            // M-2 will implement the error UI; show minimal placeholder for now
            SkeletonBlock(height: 60)
                .padding(8)
        }
    }

    // MARK: - Rendering

    @MainActor
    private func triggerRender() async {
        renderState = .loading
        do {
            try Task.checkCancellation()
            let (image, aspectRatio) = try await renderer.render(
                source: source,
                theme: theme
            )
            try Task.checkCancellation()
            renderState = .success(image, aspectRatio)
        } catch is CancellationError {
            // 任务已取消，保持 loading（下一个 task 会接管）
        } catch {
            renderState = .failure(error.localizedDescription)
        }
    }
}
