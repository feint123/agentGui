//
//  AttachedFile.swift
//  agentGui
//
//  Created by feint on 2026/2/10.
//

import Foundation

/// 引用文件（仅保存路径，不读取内容）
struct AttachedFile: Identifiable {
    let id = UUID()
    let name: String
    let url: URL

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
