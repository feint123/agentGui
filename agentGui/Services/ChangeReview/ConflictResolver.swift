import CryptoKit
import Foundation

enum ChangeReviewConflictError: LocalizedError, Equatable {
    case baseChanged(String)
    case draftChanged(String)
    case unsupportedDiff(String)

    var errorDescription: String? {
        switch self {
        case .baseChanged(let path):
            return "应用失败：文件 '\(path)' 在提案生成后已发生变化。"
        case .draftChanged(let path):
            return "确认失败：文件 '\(path)' 在草稿生成后已被再次修改。"
        case .unsupportedDiff(let path):
            return "应用失败：暂不支持直接应用 '\(path)' 的 patch 格式。"
        }
    }
}

struct ConflictResolver {
    func currentContentHash(at fileURL: URL) throws -> String? {
        let fileManager = FileManager.default
        let currentText: String?
        if fileManager.fileExists(atPath: fileURL.path) {
            currentText = try String(contentsOf: fileURL, encoding: .utf8)
        } else {
            currentText = nil
        }

        return contentHash(for: currentText)
    }

    func validateBaseHash(currentFileURL: URL, expectedHash: String?) throws {
        let currentHash = try currentContentHash(at: currentFileURL)
        if currentHash != expectedHash {
            throw ChangeReviewConflictError.baseChanged(currentFileURL.path)
        }
    }

    private func contentHash(for text: String?) -> String? {
        guard let text else { return nil }
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}