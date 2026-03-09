import Foundation
import Testing
@testable import agentGui

@MainActor
struct BashPromptAnalyzerTests {

    @Test func detectsYesNoPrompt() async throws {
        let decision = BashPromptAnalyzer().analyze(output: "Proceed? (y/N)")

        #expect(decision?.snapshot.kind == .yesNo)
        #expect(decision?.shouldAutoReply == true)
        #expect(decision?.autoReplyText == "n")
    }

    @Test func marksPasswordPromptAsNeedsUserDecision() async throws {
        let decision = BashPromptAnalyzer().analyze(output: "Password:")

        #expect(decision?.snapshot.kind == .secret)
        #expect(decision?.shouldAutoReply == false)
        #expect(decision?.escalationReason == "sensitive-input")
    }

    @Test func detectsOverwritePromptAsUnsafeAutoReply() async throws {
        let decision = BashPromptAnalyzer().analyze(output: "File exists. Overwrite? [y/N]")

        #expect(decision?.snapshot.kind == .destructiveConfirmation)
        #expect(decision?.shouldAutoReply == false)
    }

    @Test func detectsPressEnterPrompt() async throws {
        let decision = BashPromptAnalyzer().analyze(output: "Press Enter to continue")

        #expect(decision?.snapshot.kind == .pressEnter)
        #expect(decision?.shouldAutoReply == true)
        #expect(decision?.autoReplyText == "")
    }

    @Test func returnsNilForPlainOutput() async throws {
        let decision = BashPromptAnalyzer().analyze(output: "Compiled 17 files successfully")

        #expect(decision == nil)
    }

        @Test func userQuestionForDestructivePromptUsesPromptOptions() async throws {
                let decision = try #require(BashPromptAnalyzer().analyze(output: "File exists. Overwrite? [y/N]"))

                let questions = ClaudeService().makeAskUserQuestions(for: decision)

                #expect(questions.count == 1)
                #expect(questions[0].header == "Bash Prompt")
                #expect(questions[0].options.map(\.label) == ["y", "n"])
                #expect(questions[0].multiSelect == false)
        }

        @Test func userQuestionForSecretPromptOffersSafeChoicesOnly() async throws {
                let decision = try #require(BashPromptAnalyzer().analyze(output: "Password:"))

                let questions = ClaudeService().makeAskUserQuestions(for: decision)

                #expect(questions.count == 1)
                #expect(questions[0].options.map(\.label) == ["Cancel command", "Keep waiting"])
        }

        @Test func selectedPromptAnswerMapsToReplyAction() async throws {
                let decision = try #require(BashPromptAnalyzer().analyze(output: "Proceed? (y/N)"))
                let payload = """
                {
                    "answers": [
                        {
                            "question": "Proceed? (y/N)",
                            "header": "Bash Prompt",
                            "selected": ["y"]
                        }
                    ]
                }
                """

                let action = ClaudeService().resolvePromptUserAction(from: payload, decision: decision)

                #expect(action == .reply("y"))
        }

        @Test func selectedSecretPromptCancelMapsToInterruptAction() async throws {
                let decision = try #require(BashPromptAnalyzer().analyze(output: "Password:"))
                let payload = """
                {
                    "answers": [
                        {
                            "question": "Password:",
                            "header": "Bash Prompt",
                            "selected": ["Cancel command"]
                        }
                    ]
                }
                """

                let action = ClaudeService().resolvePromptUserAction(from: payload, decision: decision)

                #expect(action == .interrupt)
        }
}