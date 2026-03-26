import Testing
@testable import agentGui

struct VoiceInputButtonPresentationTests {
    @Test
    func idlePhaseUsesMicrophoneSymbol() {
        let presentation = VoiceInputButtonPresentation.make(phase: .idle, isEnabled: true)

        #expect(presentation.symbolName == "mic.fill")
        #expect(presentation.isEmphasized == false)
    }

    @Test
    func recordingPhaseUsesStopSymbolAndEmphasis() {
        let presentation = VoiceInputButtonPresentation.make(phase: .recording, isEnabled: true)

        #expect(presentation.symbolName == "stop.circle.fill")
        #expect(presentation.isEmphasized)
    }

    @Test
    func failedPhaseStaysRetryable() {
        let presentation = VoiceInputButtonPresentation.make(phase: .failed("x"), isEnabled: true)

        #expect(presentation.symbolName == "mic.fill")
        #expect(presentation.isEnabled)
    }
}