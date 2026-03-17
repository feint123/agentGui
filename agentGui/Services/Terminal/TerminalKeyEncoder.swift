import Foundation

struct TerminalKeyEncoder {
    func encode(_ key: TerminalKey) -> String {
        switch key {
        case .enter:
            return "\r"
        case .space:
            return " "
        case .tab:
            return "\t"
        case .up:
            return "\u{1B}[A"
        case .down:
            return "\u{1B}[B"
        case .left:
            return "\u{1B}[D"
        case .right:
            return "\u{1B}[C"
        }
    }
}