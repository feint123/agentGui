import CoreGraphics
import Foundation

struct AgentStudioProjection: Equatable, Sendable {
    var characters: [AgentCharacterState]
    var studioTheme: StudioTheme
    var clockTick: Date

    static let empty = AgentStudioProjection(
        characters: [],
        studioTheme: .pixelOffice,
        clockTick: .distantPast
    )
}

struct AgentCharacterState: Equatable, Identifiable, Sendable {
    let id: String
    let displayName: String
    let characterSkin: CharacterSkin
    let animationState: CharacterAnimationState
    let workstation: WorkstationSlot
    let speechBubble: SpeechBubblePresentation?
    let progressRatio: Double
    let currentToolName: String?
}

enum CharacterAnimationState: String, Equatable, Sendable {
    case idle
    case thinking
    case typing
    case reading
    case celebrating
    case error
    case sleeping
    case walking

    static func make(phase: AgentLoopPhase?, toolName: String?) -> CharacterAnimationState {
        guard let phase else {
            return .idle
        }

        switch phase {
        case .idle:
            return .idle
        case .executing, .resumingAfterPause:
            return .thinking
        case .awaitingToolResults:
            return isReadingTool(toolName) ? .reading : .typing
        case .continuingTruncatedResponse:
            return .typing
        case .finalizing:
            return .celebrating
        case .failed:
            return .error
        case .cancelled:
            return .idle
        }
    }

    private static func isReadingTool(_ toolName: String?) -> Bool {
        guard let toolName else {
            return false
        }

        let normalized = toolName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else {
            return false
        }

        let readingTokens = [
            "read_file",
            "list_dir",
            "grep_search",
            "search_files",
            "read_tool_payload",
            "查看",
            "读取",
            "搜索"
        ]

        return readingTokens.contains(where: { normalized.contains($0) })
    }
}

enum CharacterSkin: String, CaseIterable, Sendable {
    case coder
    case wizard
    case robot
    case detective
}

enum WorkstationSlot: Int, CaseIterable, Identifiable, Sendable {
    case slot1
    case slot2
    case slot3
    case slot4
    case slot5
    case slot6
    case slot7
    case slot8

    var id: Int { rawValue }

    var scenePosition: CGPoint {
        let row = rawValue / 4
        let column = rawValue % 4
        return CGPoint(
            x: 40 + (column * 72),
            y: 120 - (row * 70)
        )
    }
}

struct SpeechBubblePresentation: Equatable, Sendable {
    enum BubbleKind: Equatable, Sendable {
        case thought
        case speech
        case action
    }

    let text: String
    let kind: BubbleKind
}

enum StudioTheme: String, Sendable {
    case pixelOffice
    case nightMode
    case retro8bit
}