import SwiftUI

struct VoiceInputButtonPresentation: Equatable {
    let symbolName: String
    let isEnabled: Bool
    let isEmphasized: Bool

    static func make(phase: VoiceInputPhase, isEnabled: Bool) -> VoiceInputButtonPresentation {
        switch phase {
        case .requestingPermission, .preparing, .installingModel:
            return VoiceInputButtonPresentation(
                symbolName: "xmark.circle.fill",
                isEnabled: isEnabled,
                isEmphasized: true
            )
        case .recording, .finalizing:
            return VoiceInputButtonPresentation(
                symbolName: "stop.circle.fill",
                isEnabled: isEnabled,
                isEmphasized: true
            )
        case .idle, .failed(_):
            return VoiceInputButtonPresentation(
                symbolName: "mic.fill",
                isEnabled: isEnabled,
                isEmphasized: false
            )
        }
    }
}

struct VoiceInputButton: View {
    let phase: VoiceInputPhase
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        let presentation = VoiceInputButtonPresentation.make(phase: phase, isEnabled: isEnabled)

        Button(action: action) {
            Image(systemName: presentation.symbolName)
                .font(.system(size: 16))
                .foregroundStyle(presentation.isEmphasized ? Color.red : Color.accentColor)
        }
        .buttonStyle(.plain)
        .disabled(presentation.isEnabled == false)
        .accessibilityIdentifier("chat.voiceInputButton")
    }
}