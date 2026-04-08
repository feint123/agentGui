//
//  AttachmentEntryChipViewTests.swift
//  agentGuiTests
//

import Testing
import Foundation
import SwiftUI
@testable import agentGui

struct AttachmentEntryChipViewTests {

    // MARK: - AttachedFile origin & uploadStatus

    @Test
    func attachedFileDefaultOriginIsExternal() {
        let file = AttachedFile(name: "photo.png", url: URL(fileURLWithPath: "/tmp/photo.png"))
        #expect(file.origin == .external)
    }

    @Test
    func attachedFileAcceptsFocusedOrigin() {
        let file = AttachedFile(
            name: "main.swift",
            url: URL(fileURLWithPath: "/tmp/main.swift"),
            origin: .focused
        )
        #expect(file.origin == .focused)
    }

    @Test
    func attachedFileDefaultUploadStatusIsPending() {
        let file = AttachedFile(name: "doc.pdf", url: URL(fileURLWithPath: "/tmp/doc.pdf"))
        #expect(file.uploadStatus == .pending)
    }

    // MARK: - _ChipContainer config

    @Test
    func chipContainerShowsRemoveOnlyWhenCallbackProvided() {
        let withRemove = ChipContainerConfig(tint: .blue, onRemove: { })
        let withoutRemove = ChipContainerConfig(tint: .blue, onRemove: nil)
        #expect(withRemove.hasRemoveButton == true)
        #expect(withoutRemove.hasRemoveButton == false)
    }

    @Test
    func chipContainerIsLoadingWhenUploadStatusIsUploading() {
        #expect(ChipContainerConfig.isLoading(for: .uploading) == true)
        #expect(ChipContainerConfig.isLoading(for: .pending) == false)
        #expect(ChipContainerConfig.isLoading(for: .uploaded) == false)
    }

    // MARK: - 来源 tint 颜色

    @Test
    func tintColorForFocusedOriginIsOrange() {
        #expect(AttachmentOriginTint.color(for: .focused) == .orange)
        #expect(AttachmentOriginTint.color(for: .project) == .accentColor)
        #expect(AttachmentOriginTint.color(for: .external) == .secondary)
    }
}
