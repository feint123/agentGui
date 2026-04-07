import Foundation

struct GitCommit: Identifiable, Equatable {
    let sha: String
    let message: String       // 首行（摘要）
    let fullMessage: String   // 完整 commit body
    let author: String
    let authorEmail: String
    let date: Date

    var id: String { sha }

    var shortSha: String {
        String(sha.prefix(7))
    }
}
