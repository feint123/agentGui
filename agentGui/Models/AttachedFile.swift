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
}
