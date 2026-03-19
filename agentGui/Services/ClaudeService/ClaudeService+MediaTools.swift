//
//  ClaudeService+MediaTools.swift
//  agentGui
//

import Foundation
import PDFKit
import Vision
import SwiftAnthropic

extension ClaudeService {

    // MARK: - analyze_image

    /// Load a local image file and inject it as a Vision content block so Claude can
    /// see and describe the image. Supports png, jpg, jpeg, gif, webp (≤ 20 MB).
    func executeAnalyzeImageTool(input: MessageResponse.Content.Input) async -> ToolExecutionResult {
        guard let path = input["file_path"]?.stringValue else {
            return .missingParameter("file_path")
        }
        let url = URL(fileURLWithPath: path)
        guard AttachedFile.pathIsImage(path) else {
            return .failure("Error: '\(url.lastPathComponent)' is not a supported image type (png, jpg, jpeg, gif, webp)")
        }
        guard FileManager.default.fileExists(atPath: path) else {
            return .failure("Error: file not found at path: \(path)")
        }

        do {
            let data = try Data(contentsOf: url)
            guard data.count <= 20 * 1024 * 1024 else {
                return .failure("Error: image file exceeds 20 MB limit (\(data.count / 1024 / 1024) MB)")
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

            // Run Vision OCR on the image
            let ocrText = await Self.extractText(from: data)
            let textSection: String
            if ocrText.isEmpty {
                textSection = "(No text detected by OCR)"
            } else {
                textSection = ocrText
            }

            return .success(
                """
                Image: \(url.lastPathComponent)

                === OCR Extracted Text ===
                \(textSection)
                === End OCR Text ===

                The image is attached above. Analyze both the visual content and the extracted text.
                """,
                mediaContent: [.image(imageSource)]
            )
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoPermissionError {
            return .permissionDenied("Error: permission denied reading image file: \(url.lastPathComponent)")
        } catch {
            return .failure("Error reading image file: \(error.localizedDescription)")
        }
    }

    // MARK: - Vision OCR helper

    /// Extract all text from image data using VNRecognizeTextRequest.
    private static func extractText(from data: Data) async -> String {
        await withCheckedContinuation { continuation in
            guard let cgImage = { () -> CGImage? in
                guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
                return CGImageSourceCreateImageAtIndex(src, 0, nil)
            }() else {
                continuation.resume(returning: "")
                return
            }

            let request = VNRecognizeTextRequest { req, error in
                guard error == nil,
                      let observations = req.results as? [VNRecognizedTextObservation] else {
                    continuation.resume(returning: "")
                    return
                }
                let lines = observations.compactMap { $0.topCandidates(1).first?.string }
                continuation.resume(returning: lines.joined(separator: "\n"))
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(returning: "")
            }
        }
    }

    // MARK: - read_pdf

    /// Extract all selectable text from a local PDF file using PDFKit (≤ 50 MB).
    /// Returns the text page-by-page so Claude can understand the document content.
    func executeReadPDFTool(input: MessageResponse.Content.Input) async -> ToolExecutionResult {
        guard let path = input["file_path"]?.stringValue else {
            return .missingParameter("file_path")
        }
        let url = URL(fileURLWithPath: path)
        guard AttachedFile.pathIsPDF(path) else {
            return .failure("Error: '\(url.lastPathComponent)' is not a PDF file")
        }
        guard FileManager.default.fileExists(atPath: path) else {
            return .failure("Error: file not found at path: \(path)")
        }

        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let size = attrs[.size] as? Int, size > 50 * 1024 * 1024 {
            return .failure("Error: PDF file exceeds 50 MB limit (\(size / 1024 / 1024) MB)")
        }

        let (pdfText, succeeded) = await Task.detached(priority: .userInitiated) { [url] in
            guard let pdf = PDFDocument(url: url) else {
                return ("Error: could not open PDF document", false)
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
                return (header + "(No selectable text found. This PDF may contain only scanned images.)", true)
            }
            return (header + pages.joined(separator: "\n\n"), true)
        }.value
        return succeeded ? ToolExecutionResult(pdfText) : .failure(pdfText)
    }
}
