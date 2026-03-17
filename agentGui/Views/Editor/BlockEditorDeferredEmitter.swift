import Foundation

@MainActor
final class BlockEditorDeferredEmitter<Value: Equatable> {
    private let handler: (Value) -> Void
    private var pendingValue: Value?
    private var deliveryScheduled = false

    init(handler: @escaping (Value) -> Void) {
        self.handler = handler
    }

    func send(_ value: Value) {
        pendingValue = value
        guard !deliveryScheduled else { return }
        deliveryScheduled = true

        DispatchQueue.main.async { [weak self] in
            guard let self, let value = self.pendingValue else {
                self?.deliveryScheduled = false
                return
            }
            self.pendingValue = nil
            self.deliveryScheduled = false
            self.handler(value)
        }
    }
}