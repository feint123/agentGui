//
//  AttachedFile.swift
//  agentGui
//
//  Created by feint on 2026/2/10.
//

import Foundation

/// 附件来源，区分三种文件引用类型。
/// CV-FA2 会将同名枚举镜像到 MessageAttachment.originRaw 持久化字段。
enum AttachmentOrigin: String, Codable, Equatable {
    case project   // @Mention 项目文件
    case focused   // 当前聚焦文件 / 编辑器选区
    case external  // 用户手动拖入或附加的外部文件
}

/// 引用文件（仅保存路径，不读取内容）
struct AttachedFile: Identifiable {
    let id = UUID()
    let name: String
    let url: URL
    var origin: AttachmentOrigin = .external
    var uploadStatus: UploadStatus = .pending

    // CV-FA2: 聚焦文件专用字段
    var selectedText: String? = nil
    var lineStart: Int? = nil
    var lineEnd: Int? = nil

    enum UploadStatus: Equatable {
        case pending    // 等待（本地文件通常常驻此态）
        case uploading  // 上传中（未来远程文件使用）
        case uploaded   // 完成
    }

    var path: String { url.path }

    var isImage: Bool { AttachedFile.pathIsImage(url.path) }
    var isPDF: Bool { AttachedFile.pathIsPDF(url.path) }

    static func pathIsImage(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp"].contains(ext)
    }

    static func pathIsPDF(_ path: String) -> Bool {
        (path as NSString).pathExtension.lowercased() == "pdf"
    }
}
