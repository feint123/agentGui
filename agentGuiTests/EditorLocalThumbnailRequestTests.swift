import Foundation
import Testing
@testable import agentGui

struct EditorLocalThumbnailRequestTests {

    @Test func requestNormalizesToStandardizedPathAndPixelWidth() {
        let url = URL(fileURLWithPath: "/tmp/images/../images/photo.png")

        let request = EditorLocalThumbnailRequest(fileURL: url, targetWidth: 320.2, scale: 2)

        #expect(request.cacheKey.path == "/tmp/images/photo.png")
        #expect(request.cacheKey.pixelWidth == 641)
    }

    @Test func requestKeepsDistinctWidthsInSeparateCacheBuckets() {
        let url = URL(fileURLWithPath: "/tmp/images/photo.png")

        let narrow = EditorLocalThumbnailRequest(fileURL: url, targetWidth: 240, scale: 2)
        let wide = EditorLocalThumbnailRequest(fileURL: url, targetWidth: 360, scale: 2)

        #expect(narrow.cacheKey != wide.cacheKey)
    }

    @Test func requestClampsTinyWidthsToOnePixelBucket() {
        let url = URL(fileURLWithPath: "/tmp/images/photo.png")

        let request = EditorLocalThumbnailRequest(fileURL: url, targetWidth: 0.2, scale: 1)

        #expect(request.cacheKey.pixelWidth == 1)
    }
}