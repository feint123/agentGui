import Foundation
@testable import agentGui

enum TerminalRenderFixtures {
    static let inverseWarningSnapshot = TerminalScreenSnapshot(
        lines: [
            TerminalScreenLine(cells: [
                TerminalScreenCell(
                    text: "W",
                    foreground: .ansi16(.yellow),
                    background: .defaultBackground,
                    attributes: [.inverse]
                ),
                TerminalScreenCell(
                    text: "A",
                    foreground: .ansi16(.yellow),
                    background: .defaultBackground,
                    attributes: [.inverse]
                ),
                TerminalScreenCell(
                    text: "R",
                    foreground: .ansi16(.yellow),
                    background: .defaultBackground,
                    attributes: [.inverse]
                ),
                TerminalScreenCell(
                    text: "N",
                    foreground: .ansi16(.yellow),
                    background: .defaultBackground,
                    attributes: [.inverse]
                )
            ])
        ],
        plainTextLines: ["WARN"],
        activeBuffer: .primary,
        cursor: .init(row: 0, column: 4),
        width: 80,
        height: 24
    )

    static let coloredDiffSnapshot = TerminalScreenSnapshot(
        lines: [
            TerminalScreenLine(cells: [
                TerminalScreenCell(text: "+", foreground: .ansi16(.brightGreen), attributes: [.bold]),
                TerminalScreenCell(text: " "),
                TerminalScreenCell(text: "n", foreground: .ansi16(.brightGreen), attributes: [.bold]),
                TerminalScreenCell(text: "e", foreground: .ansi16(.brightGreen), attributes: [.bold]),
                TerminalScreenCell(text: "w", foreground: .ansi16(.brightGreen), attributes: [.bold]),
                TerminalScreenCell(text: " "),
                TerminalScreenCell(text: "l", foreground: .rgb(red: 80, green: 160, blue: 255), attributes: [.underline]),
                TerminalScreenCell(text: "i", foreground: .rgb(red: 80, green: 160, blue: 255), attributes: [.underline]),
                TerminalScreenCell(text: "n", foreground: .rgb(red: 80, green: 160, blue: 255), attributes: [.underline]),
                TerminalScreenCell(text: "e", foreground: .rgb(red: 80, green: 160, blue: 255), attributes: [.underline])
            ])
        ],
        plainTextLines: ["+ new line"],
        activeBuffer: .primary,
        cursor: .init(row: 0, column: 10),
        width: 80,
        height: 24
    )

    static let createVueSelectionSnapshot = TerminalScreenSnapshot(
        plainTextLines: TerminalInteractiveFixtures.createVueFeatureSelectionScreen
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init),
        activeBuffer: .alternate,
        cursor: .init(row: 4, column: 0),
        width: 80,
        height: 24
    )
}