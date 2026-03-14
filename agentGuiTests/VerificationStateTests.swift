import Foundation
import Testing
@testable import agentGui

struct VerificationStateTests {
    @Test func completionVerificationDecodesLegacyPayloadWithoutVerificationState() throws {
        let data = Data(#"""
        {
          "verified": ["unit tests passed"],
          "not_verified": [],
          "conclusion": "looks good"
        }
        """#.utf8)

        let decoded = try JSONDecoder().decode(CompletionVerification.self, from: data)

        #expect(decoded.verified == ["unit tests passed"])
        #expect(decoded.verificationState == nil)
    }
}