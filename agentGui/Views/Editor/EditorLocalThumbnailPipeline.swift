import AppKit
import Combine
import Foundation
import ImageIO
import PDFKit

struct EditorLocalThumbnailCacheKey: Hashable {
    let path: String
    let pixelWidth: Int
}

struct EditorLocalThumbnailRequest: Hashable {
    let fileURL: URL
    let targetWidth: CGFloat
    let scale: CGFloat
    let cacheKey: EditorLocalThumbnailCacheKey

    init(fileURL: URL, targetWidth: CGFloat, scale: CGFloat = 2) {
        let standardizedURL = fileURL.standardizedFileURL
        let pixelWidth = max(1, Int(ceil(targetWidth * scale)))
        self.fileURL = standardizedURL
        self.targetWidth = targetWidth
        self.scale = scale
        self.cacheKey = EditorLocalThumbnailCacheKey(path: standardizedURL.path, pixelWidth: pixelWidth)
    }
}

actor EditorLocalThumbnailPipeline {
    static let shared = EditorLocalThumbnailPipeline()

    private let cache = NSCache<NSString, NSImage>()
    private var inFlightTasks: [EditorLocalThumbnailCacheKey: Task<NSImage?, Never>] = [:]

    func image(for request: EditorLocalThumbnailRequest) async -> NSImage? {
        let key = cacheKeyString(for: request.cacheKey)
        if let cached = cache.object(forKey: key) {
            return cached
        }
        if let existingTask = inFlightTasks[request.cacheKey] {
            return await existingTask.value
        }

        let task = Task(priority: .utility) {
            await Self.makeThumbnail(for: request)
        }
        inFlightTasks[request.cacheKey] = task

        let image = await task.value
        inFlightTasks[request.cacheKey] = nil
        if let image {
            cache.setObject(image, forKey: key)
        }
        return image
    }

    private func cacheKeyString(for key: EditorLocalThumbnailCacheKey) -> NSString {
        "\(key.path)#\(key.pixelWidth)" as NSString
    }

    private static func makeThumbnail(for request: EditorLocalThumbnailRequest) async -> NSImage? {
        await Task.detached(priority: .utility) {
            if request.fileURL.pathExtension.lowercased() == "pdf",
               let document = PDFDocument(url: request.fileURL),
               let page = document.page(at: 0) {
                let bounds = page.bounds(for: .mediaBox)
                let scale = CGFloat(request.cacheKey.pixelWidth) / max(bounds.width, bounds.height, 1)
                let size = NSSize(width: bounds.width * scale, height: bounds.height * scale)
                return NSImage(size: size, flipped: false) { _ in
                    guard let context = NSGraphicsContext.current?.cgContext else { return false }
                    context.setFillColor(NSColor.controlBackgroundColor.cgColor)
                    context.fill(CGRect(origin: .zero, size: size))
                    context.scaleBy(x: scale, y: scale)
                    page.draw(with: .mediaBox, to: context)
                    return true
                }
            }

            let options: CFDictionary = [
                kCGImageSourceShouldCache: false,
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: request.cacheKey.pixelWidth
            ] as CFDictionary

            guard let imageSource = CGImageSourceCreateWithURL(request.fileURL as CFURL, nil),
                  let cgImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options) else {
                return nil
            }

            let size = NSSize(width: cgImage.width, height: cgImage.height)
            return NSImage(cgImage: cgImage, size: size)
        }.value
    }
}

@MainActor
final class EditorLocalThumbnailLoader: ObservableObject {
    @Published private(set) var image: NSImage?
    @Published private(set) var isLoading = false

    private var currentKey: EditorLocalThumbnailCacheKey?
    private var loadTask: Task<Void, Never>?

    func load(fileURL: URL, targetWidth: CGFloat, scale: CGFloat = 2) {
        let request = EditorLocalThumbnailRequest(fileURL: fileURL, targetWidth: targetWidth, scale: scale)
        guard currentKey != request.cacheKey else { return }

        currentKey = request.cacheKey
        image = nil
        isLoading = true
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            let image = await EditorLocalThumbnailPipeline.shared.image(for: request)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard self?.currentKey == request.cacheKey else { return }
                self?.image = image
                self?.isLoading = false
            }
        }
    }

    func reset() {
        currentKey = nil
        image = nil
        isLoading = false
        loadTask?.cancel()
        loadTask = nil
    }

    deinit {
        loadTask?.cancel()
    }
}