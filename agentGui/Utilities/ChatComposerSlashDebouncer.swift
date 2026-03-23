import Foundation

@MainActor
final class ChatComposerSlashDebouncer {
    private let debounceNanoseconds: UInt64
    private var debounceTask: Task<Void, Never>?

    init(debounceNanoseconds: UInt64 = 120_000_000) {
        self.debounceNanoseconds = debounceNanoseconds
    }

    deinit {
        debounceTask?.cancel()
    }

    func schedule(text: String, apply: @escaping @MainActor (String) -> Void) {
        debounceTask?.cancel()
        debounceTask = Task { [debounceNanoseconds] in
            try? await Task.sleep(nanoseconds: debounceNanoseconds)
            guard !Task.isCancelled else { return }
            apply(text)
        }
    }

    func cancel() {
        debounceTask?.cancel()
        debounceTask = nil
    }
}
