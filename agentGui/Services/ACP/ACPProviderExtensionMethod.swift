import Foundation

struct ACPProviderExtensionMethod: Equatable, Sendable {
    let method: String

    init(_ method: String) {
        precondition(method.hasPrefix("_"), "ACP extension methods must start with underscore")
        self.method = method
    }
}