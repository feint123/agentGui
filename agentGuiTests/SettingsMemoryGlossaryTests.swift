import Foundation
import Testing
@testable import agentGui

struct SettingsMemoryGlossaryTests {

    @Test func glossaryCoversCoreRMSTerms() {
        let terms = SettingsMemoryGlossary.defaultItems.map(\.term)

        #expect(terms.contains("RMS"))
        #expect(terms.contains("RMS State"))
        #expect(terms.contains("RMSInsight"))
        #expect(terms.contains("Frontier"))
        #expect(terms.contains("Counterexample"))
        #expect(terms.contains("Constraint"))
        #expect(terms.contains("Verification Debt"))
        #expect(terms.contains("Bootstrap Prompt"))
    }

    @Test func glossaryExplainsMemoryContextBudgetAsSelectionLimit() {
        let budgetItem = SettingsMemoryGlossary.defaultItems.first(where: { $0.term == "Memory 上下文预算" })

        #expect(budgetItem != nil)
        #expect(budgetItem?.detail.contains("最多") == true)
        #expect(budgetItem?.detail.contains("RMSInsight") == true)
    }
}