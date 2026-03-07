//
//  ClaudeService+MediaTools.swift
//  agentGui
//

import Foundation
import PDFKit
import SwiftAnthropic

extension ClaudeService {

    // MARK: - analyze_image

    /// Load a local image file and inject it as a Vision content block so Claude can
    /// see and describe the image. Supports png, jpg, jpeg, gif, webp (≤ 20 MB).
    func executeAnalyzeImageTool(input: MessageResponse.Content.Input) async -> ToolExecutionResult {
        guard let path = input["file_path"]?.stringValue else {
            return ToolExecutionResult("Error: missing 'file_path' parameter")
        }
        let url = URL(fileURLWithPath: path)
        guard AttachedFile.pathIsImage(path) else {
            return ToolExecutionResult("Error: '\(url.lastPathComponent)' is not a supported image type (png, jpg, jpeg, gif, webp)")
        }
        guard FileManager.default.fileExists(atPath: path) else {
            return ToolExecutionResult("Error: file not found at path: \(path)")
        }

        do {
            let data = try Data(contentsOf: url)
            guard data.count <= 20 * 1024 * 1024 else {
                return ToolExecutionResult("Error: image file exceeds 20 MB limit (\(data.count / 1024 / 1024) MB)")
            }

            let ext = url.pathExtension.lowercased()
            let mediaType: MessageParameter.Message.Content.ImageSource.MediaType
            switch ext {
            case "jpg", "jpeg": mediaType = .jpeg
            case "gif":         mediaType = .gif
            case "webp":        mediaType = .webp
            default:            mediaType = .png
            }

            let base64 = data.base64EncodedString()
            let imageSource = MessageParameter.Message.Content.ImageSource(
                type: .base64,
                mediaType: mediaType,
                data: base64
            )

            return ToolExecutionResult(
                "Image loaded: \(url.lastPathComponent). Analyze the image content shown above.",
                mediaContent: [.image(imageSource)]
            )
        } catch {
            return ToolExecutionResult("Error reading image file: \(error.localizedDescription)")
        }
    }

    // MARK: - read_pdf

    /// Extract all selectable text from a local PDF file using PDFKit (≤ 50 MB).
    /// Returns the text page-by-page so Claude can understand the document content.
    func executeReadPDFTool(input: MessageResponse.Content.Input) async -> ToolExecutionResult {
        guard let path = input["file_path"]?.stringValue else {
            return ToolExecutionResult("Error: missing 'file_path' parameter")
        }
        let url = URL(fileURLWithPath: path)
        guard AttachedFile.pathIsPDF(path) else {
            return ToolExecutionResult("Error: '\(url.lastPathComponent)' is not a PDF file")
        }
        guard FileManager.default.fileExists(atPath: path) else {
            return ToolExecutionResult("Error: file not found at path: \(path)")
        }

        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let size = attrs[.size] as? Int, size > 50 * 1024 * 1024 {
            return ToolExecutionResult("Error: PDF file exceeds 50 MB limit (\(size / 1024 / 1024) MB)")
        }

        return await Task.detached(priority: .userInitiated) { [url] in
            guard let pdf = PDFDocument(url: url) else {
                return ToolExecutionResult("Error: could not open PDF document")
            }

            let pageCount = pdf.pageCount
            var pages: [String] = []
            for i in 0..<pageCount {
                if let page = pdf.page(at: i), let text = page.string, !text.isEmpty {
                    pages.append("--- Page \(i + 1) ---\n\(text)")
                }
            }

            let header = "PDF: \(url.lastPathComponent)\nPages: \(pageCount)\n\n"
            if pages.isEmpty {
                return ToolExecutionResult(header + "(No selectable text found. This PDF may contain only scanned images.)")
            }
            return ToolExecutionResult(header + pages.joined(separator: "\n\n"))
        }.value
    }
}
