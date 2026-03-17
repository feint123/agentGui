import AppKit
import Foundation

struct TerminalScreenTheme {
    var defaultForegroundColor: NSColor
    var defaultBackgroundColor: NSColor
    var cursorColor: NSColor
    var ansiPalette: [TerminalANSI16Color: NSColor]

    static let darkDefault = TerminalScreenTheme(
        defaultForegroundColor: NSColor(calibratedRed: 0.88, green: 0.90, blue: 0.93, alpha: 1),
        defaultBackgroundColor: NSColor(calibratedRed: 0.08, green: 0.09, blue: 0.11, alpha: 1),
        cursorColor: NSColor(calibratedRed: 0.95, green: 0.97, blue: 1.0, alpha: 1),
        ansiPalette: Self.palette(
            black: NSColor(calibratedRed: 0.12, green: 0.13, blue: 0.16, alpha: 1),
            red: NSColor(calibratedRed: 0.86, green: 0.31, blue: 0.31, alpha: 1),
            green: NSColor(calibratedRed: 0.44, green: 0.76, blue: 0.43, alpha: 1),
            yellow: NSColor(calibratedRed: 0.90, green: 0.76, blue: 0.39, alpha: 1),
            blue: NSColor(calibratedRed: 0.39, green: 0.63, blue: 0.94, alpha: 1),
            magenta: NSColor(calibratedRed: 0.78, green: 0.50, blue: 0.88, alpha: 1),
            cyan: NSColor(calibratedRed: 0.36, green: 0.78, blue: 0.82, alpha: 1),
            white: NSColor(calibratedRed: 0.88, green: 0.90, blue: 0.93, alpha: 1),
            brightBlack: NSColor(calibratedRed: 0.37, green: 0.40, blue: 0.45, alpha: 1),
            brightRed: NSColor(calibratedRed: 0.96, green: 0.46, blue: 0.46, alpha: 1),
            brightGreen: NSColor(calibratedRed: 0.55, green: 0.88, blue: 0.51, alpha: 1),
            brightYellow: NSColor(calibratedRed: 0.97, green: 0.83, blue: 0.49, alpha: 1),
            brightBlue: NSColor(calibratedRed: 0.52, green: 0.76, blue: 1.0, alpha: 1),
            brightMagenta: NSColor(calibratedRed: 0.89, green: 0.62, blue: 0.96, alpha: 1),
            brightCyan: NSColor(calibratedRed: 0.50, green: 0.88, blue: 0.93, alpha: 1),
            brightWhite: NSColor(calibratedRed: 0.98, green: 0.99, blue: 1.0, alpha: 1)
        )
    )

    static let lightDefault = TerminalScreenTheme(
        defaultForegroundColor: NSColor(calibratedRed: 0.12, green: 0.14, blue: 0.17, alpha: 1),
        defaultBackgroundColor: NSColor(calibratedRed: 0.97, green: 0.97, blue: 0.95, alpha: 1),
        cursorColor: NSColor(calibratedRed: 0.10, green: 0.12, blue: 0.14, alpha: 1),
        ansiPalette: Self.palette(
            black: NSColor(calibratedRed: 0.17, green: 0.19, blue: 0.22, alpha: 1),
            red: NSColor(calibratedRed: 0.73, green: 0.20, blue: 0.24, alpha: 1),
            green: NSColor(calibratedRed: 0.16, green: 0.54, blue: 0.26, alpha: 1),
            yellow: NSColor(calibratedRed: 0.70, green: 0.49, blue: 0.11, alpha: 1),
            blue: NSColor(calibratedRed: 0.17, green: 0.40, blue: 0.76, alpha: 1),
            magenta: NSColor(calibratedRed: 0.56, green: 0.24, blue: 0.67, alpha: 1),
            cyan: NSColor(calibratedRed: 0.14, green: 0.53, blue: 0.61, alpha: 1),
            white: NSColor(calibratedRed: 0.75, green: 0.77, blue: 0.80, alpha: 1),
            brightBlack: NSColor(calibratedRed: 0.40, green: 0.43, blue: 0.47, alpha: 1),
            brightRed: NSColor(calibratedRed: 0.82, green: 0.28, blue: 0.31, alpha: 1),
            brightGreen: NSColor(calibratedRed: 0.21, green: 0.62, blue: 0.32, alpha: 1),
            brightYellow: NSColor(calibratedRed: 0.82, green: 0.58, blue: 0.17, alpha: 1),
            brightBlue: NSColor(calibratedRed: 0.26, green: 0.49, blue: 0.85, alpha: 1),
            brightMagenta: NSColor(calibratedRed: 0.65, green: 0.35, blue: 0.76, alpha: 1),
            brightCyan: NSColor(calibratedRed: 0.21, green: 0.64, blue: 0.72, alpha: 1),
            brightWhite: NSColor(calibratedRed: 0.88, green: 0.89, blue: 0.90, alpha: 1)
        )
    )

    func resolve(_ color: TerminalColor, fallback: NSColor) -> NSColor {
        switch color {
        case .defaultForeground, .defaultBackground:
            return fallback
        case .ansi16(let ansiColor):
            return ansiPalette[ansiColor] ?? fallback
        case .ansi256(let index):
            return Self.resolveANSI256(index, fallback: fallback)
        case .rgb(let red, let green, let blue):
            return NSColor(
                calibratedRed: CGFloat(max(0, min(red, 255))) / 255,
                green: CGFloat(max(0, min(green, 255))) / 255,
                blue: CGFloat(max(0, min(blue, 255))) / 255,
                alpha: 1
            )
        }
    }

    private static func palette(
        black: NSColor,
        red: NSColor,
        green: NSColor,
        yellow: NSColor,
        blue: NSColor,
        magenta: NSColor,
        cyan: NSColor,
        white: NSColor,
        brightBlack: NSColor,
        brightRed: NSColor,
        brightGreen: NSColor,
        brightYellow: NSColor,
        brightBlue: NSColor,
        brightMagenta: NSColor,
        brightCyan: NSColor,
        brightWhite: NSColor
    ) -> [TerminalANSI16Color: NSColor] {
        [
            .black: black,
            .red: red,
            .green: green,
            .yellow: yellow,
            .blue: blue,
            .magenta: magenta,
            .cyan: cyan,
            .white: white,
            .brightBlack: brightBlack,
            .brightRed: brightRed,
            .brightGreen: brightGreen,
            .brightYellow: brightYellow,
            .brightBlue: brightBlue,
            .brightMagenta: brightMagenta,
            .brightCyan: brightCyan,
            .brightWhite: brightWhite
        ]
    }

    private static func resolveANSI256(_ index: Int, fallback: NSColor) -> NSColor {
        let clamped = max(0, min(index, 255))
        if clamped < 16 {
            let color = TerminalANSI16Color.allCases[clamped]
            return darkDefault.ansiPalette[color] ?? fallback
        }

        if clamped >= 232 {
            let level = CGFloat(clamped - 232) / 23
            return NSColor(calibratedWhite: level, alpha: 1)
        }

        let adjusted = clamped - 16
        let red = adjusted / 36
        let green = (adjusted % 36) / 6
        let blue = adjusted % 6
        let values: [CGFloat] = [0, 95 / 255, 135 / 255, 175 / 255, 215 / 255, 1]
        return NSColor(calibratedRed: values[red], green: values[green], blue: values[blue], alpha: 1)
    }
}