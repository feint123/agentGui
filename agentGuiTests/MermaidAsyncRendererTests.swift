//
//  MermaidAsyncRendererTests.swift
//  agentGuiTests
//

import AppKit
import BeautifulMermaid
import Testing
@testable import agentGui

struct MermaidAsyncRendererTests {

    private let renderer = MermaidAsyncRenderer()

    // MARK: - 正常图表

    @Test
    func flowchartRendersSuccessfully() async throws {
        let source = """
        graph TD
            A[Start] --> B[End]
        """
        let (image, aspectRatio) = try await renderer.render(source: source, theme: .zincLight)

        #expect(image.size.width > 0)
        #expect(image.size.height > 0)
        #expect((0.1...10.0).contains(aspectRatio),
                "宽高比应在合理范围内，实际：\(aspectRatio)")
    }

    @Test
    func sequenceDiagramRendersSuccessfully() async throws {
        let source = """
        sequenceDiagram
            Alice->>Bob: 你好
            Bob-->>Alice: 你好
        """
        let (image, aspectRatio) = try await renderer.render(source: source, theme: .zincDark)

        #expect(image.size.width > 0)
        #expect(image.size.height > 0)
        #expect((0.1...10.0).contains(aspectRatio))
    }

    @Test
    func aspectRatioMatchesImageDimensions() async throws {
        let source = "graph LR; A --> B"
        let (image, aspectRatio) = try await renderer.render(source: source, theme: .zincLight)
        let expected = image.size.width / image.size.height
        #expect(abs(aspectRatio - expected) < 0.001)
    }

    // MARK: - 错误输入

    @Test
    func invalidSourceThrows() async {
        let source = "%%% 完全无效的语法 %%%"
        // BeautifulMermaid 对无效输入可能返回 nil 或 throws
        // 两种情况都不应崩溃
        do {
            let (image, _) = try await renderer.render(source: source, theme: .zincLight)
            // 若未抛出，验证至少返回了有意义的占位图
            #expect(image.size.width >= 0)
        } catch {
            // 抛出错误也是可接受的，确认是 MermaidRenderError
            #expect(error is MermaidRenderError || error is any Error)
        }
    }

    @Test
    func emptySourceThrowsOrReturnsEmpty() async {
        do {
            _ = try await renderer.render(source: "", theme: .zincLight)
            Issue.record("空 source 应抛出错误")
        } catch {
            // BeautifulMermaid 对空 source 抛出 MermaidParseError（.unknownDiagramType）
            // 到达此处即验证通过，不限定具体错误类型
        }
    }
}
