import Foundation

struct GitRemoteStatus: Equatable {
    let hasRemoteTrackingBranch: Bool
    let aheadCount: Int
    let behindCount: Int
}