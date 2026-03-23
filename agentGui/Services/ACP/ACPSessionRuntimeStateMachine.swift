import Foundation

struct ACPSessionRuntimeStateMachine: Sendable {
    enum Event: Sendable {
        case startRuntime
        case runtimeStarted
        case beginRestore
        case finishRestore
        case beginPrompt
        case finishPrompt
        case beginCancel
        case finishCancel
        case beginClose
        case finishClose
    }

    enum Error: Swift.Error, Equatable {
        case invalidTransition(from: ACPSessionRuntimePhase, event: Event)
    }

    private(set) var phase: ACPSessionRuntimePhase = .idle

    mutating func transition(_ event: Event) throws {
        switch (phase, event) {
        case (.idle, .startRuntime):
            phase = .startingRuntime
        case (.startingRuntime, .runtimeStarted):
            phase = .initializing
        case (.initializing, .beginRestore):
            phase = .restoring
        case (.initializing, .finishRestore):
            phase = .ready
        case (.restoring, .finishRestore):
            phase = .ready
        case (.ready, .beginPrompt):
            phase = .sendingTurn
        case (.sendingTurn, .finishPrompt):
            phase = .ready
        case (.ready, .beginCancel), (.sendingTurn, .beginCancel):
            phase = .cancelling
        case (.cancelling, .finishCancel):
            phase = .ready
        case (.idle, .beginClose),
             (.startingRuntime, .beginClose),
             (.initializing, .beginClose),
             (.restoring, .beginClose),
             (.ready, .beginClose),
             (.sendingTurn, .beginClose),
             (.cancelling, .beginClose):
            phase = .closing
        case (.closing, .finishClose):
            phase = .closed
        default:
            throw Error.invalidTransition(from: phase, event: event)
        }
    }
}