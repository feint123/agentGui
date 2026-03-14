import Foundation
import Testing
@testable import agentGui

struct EpistemicExtractionResponseParserTests {
    @Test func parserDecodesStructuredExtractionPayload() throws {
        let json = #"""
        {
          "objects": [
            {
              "kind": "frontier",
              "id": "f-1",
              "summary": "Need to verify shared scheme",
              "source_refs": ["message:user:0", "tool:bash:tool-1"],
              "decision_delta": "changes next action from edit to inspect",
              "evidence_level": "partial"
            }
          ],
          "rejected": [],
          "missingEvidence": ["xcodebuild -list output"],
          "decisionImpactNote": "inspect scheme before editing"
        }
        """#

        let result = try EpistemicExtractionResponseParser().parse(json)

        #expect(result.objects.count == 1)
        #expect(result.objects.first?.kind == .frontier)
        #expect(result.missingEvidence == ["xcodebuild -list output"])
        #expect(result.decisionImpactNote == "inspect scheme before editing")
    }

    @Test func parserExtractsFirstJSONObjectFromMarkdownWrappedText() throws {
        let wrapped = #"""
        Here is the extraction result:

        ```json
        {
          "objects": [],
          "rejected": [
            {
              "summary": "noise",
              "reason": "does not change next action"
            }
          ],
          "missingEvidence": [],
          "decisionImpactNote": "none"
        }
        ```
        """#

        let result = try EpistemicExtractionResponseParser().parse(wrapped)

        #expect(result.objects.isEmpty)
        #expect(result.rejected.count == 1)
        #expect(result.rejected.first?.reason == "does not change next action")
    }
}