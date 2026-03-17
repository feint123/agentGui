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

    @Test func ignoresViewerCapabilityWarningsThatBelongToInteractiveScreens() async throws {
        let decision = BashPromptAnalyzer().analyze(output: """
        WARNING: terminal is not fully functional
        Press RETURN to continue
        diff --git a/app.swift b/app.swift
        index 1234567..89abcde 100644
        --- a/app.swift
        +++ b/app.swift
        @@ -1,3 +1,3 @@
        """)

        #expect(decision == nil)
    }

    @Test func detectsPackageInstallProceedPromptAndAutoRepliesYes() async throws {
        let decision = BashPromptAnalyzer().analyze(output: "Need to install the following packages:\ncreate-vue@3.22.0\nOk to proceed? (y)")

        #expect(decision?.snapshot.kind == .yesNo)
        #expect(decision?.shouldAutoReply == true)
        #expect(decision?.autoReplyText == "y")
    }

    @Test func returnsNilForPlainOutput() async throws {
        let decision = BashPromptAnalyzer().analyze(output: "Compiled 17 files successfully")

        #expect(decision == nil)
    }

    @Test func returnsNilForCreateVueMultiSelectScreen() async throws {
        let decision = BashPromptAnalyzer().analyze(output: """
        ◆  请选择要包含的功能： (↑/↓ 切换，空格选择，a 全选，回车确认)
        │  ◻ JSX 支持
        │  ◻ Router（单页面应用开发）
        │  ◻ Pinia（状态管理）
        │  ◻ Vitest（单元测试）
        """)

        #expect(decision == nil)
    }

    @Test func returnsNilWhenInteractiveMenuAppearsAfterInstallPromptInTranscript() async throws {
        let decision = BashPromptAnalyzer().analyze(output: """
        Need to install the following packages:
        create-vue@3.22.0
        Ok to proceed? (y)

        ◆  请选择要包含的功能： (↑/↓ 切换，空格选择，a 全选，回车确认)
        │  ◻ JSX 支持
        │  ◻ Router（单页面应用开发）
        │  ◻ Pinia（状态管理）
        │  ◻ Vitest（单元测试）
        """)

        #expect(decision == nil)
    }

    @Test func terminalPlannerQuestionOffersApproveTakeoverWaitAndCancel() async throws {
        let plan = TerminalInteractionPlan(
            interactionType: "multi_select_menu",
            intentSummary: "Resolve create-vue feature selection",
            confidence: 0.42,
            nextActions: [.key(.space), .key(.enter)],
            requiresUserConfirmation: true,
            reasoningSummary: "The current command alone does not say which features should be selected"
        )

        let questions = ClaudeService().makeAskUserQuestions(for: plan, summary: plan.reasoningSummary)

        #expect(questions.count == 1)
        #expect(questions[0].header == "Terminal Plan")
        #expect(questions[0].options.map { $0.label } == ["Approve plan", "Take over manually", "Keep waiting", "Cancel command"])
    }

    @Test func selectedPlannerTakeoverMapsToUserTakeoverAction() async throws {
        let payload = """
        {
            "answers": [
                {
                    "question": "planner",
                    "header": "Terminal Plan",
                    "selected": ["Take over manually"]
                }
            ]
        }
        """

        let action = ClaudeService().resolveTerminalPlannerUserAction(from: payload)

        #expect(action == .takeOver)
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