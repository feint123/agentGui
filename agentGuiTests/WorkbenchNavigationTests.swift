import Testing
@testable import agentGui

struct WorkbenchNavigationTests {
    @Test func workbenchNavigationDefaultOrderIsStable() {
        #expect(WorkbenchNavigationItem.allCases == [.sessions, .workspace, .git, .lsp, .skills, .diagnostics])
        #expect(WorkbenchNavigationItem.defaultItem == .sessions)
    }

    @Test func lspWorkbenchItemKeepsDedicatedTabIdentity() {
        #expect(WorkbenchNavigationItem.lsp.title == "LSP")
        #expect(WorkbenchNavigationItem.lsp.accessibilityIdentifier == "workbench.tab.lsp")
    }

    @Test func launchOptionsMapLegacyTabsIntoWorkbenchItems() {
        let chatOptions = TestLaunchOptions(arguments: ["-com.agentgui.test.initialTab", "chat"])
        let gitOptions = TestLaunchOptions(arguments: ["-com.agentgui.test.initialTab", "git"])
        let lspOptions = TestLaunchOptions(arguments: ["-com.agentgui.test.initialTab", "lsp"])
        let skillsOptions = TestLaunchOptions(arguments: ["-com.agentgui.test.initialTab", "skills"])
        let reliabilityOptions = TestLaunchOptions(arguments: ["-com.agentgui.test.initialTab", "reliability"])

        #expect(chatOptions.initialWorkbenchItem == .sessions)
        #expect(gitOptions.initialWorkbenchItem == .git)
        #expect(lspOptions.initialWorkbenchItem == .lsp)
        #expect(skillsOptions.initialWorkbenchItem == .skills)
        #expect(reliabilityOptions.initialWorkbenchItem == .diagnostics)
    }
}