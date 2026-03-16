import Foundation
import Testing
@testable import agentGui

struct ModelResponseJSONExtractorTests {

    @Test func decodeExtractsJSONObjectFromMarkdownFence() throws {
        struct Payload: Codable, Equatable {
            let value: Int
        }

        let text = """
        ```json
        {
          \"value\": 7
        }
        ```
        """

        let payload = try ModelResponseJSONExtractor.decode(Payload.self, from: text)

        #expect(payload == Payload(value: 7))
    }

    @Test func decodeExtractsFirstJSONObjectFromSurroundingCommentary() throws {
        struct Payload: Codable, Equatable {
            let passed: Bool
        }

        let text = "Verifier summary below.\n{\"passed\":true}\nUse that result."

        let payload = try ModelResponseJSONExtractor.decode(Payload.self, from: text)

        #expect(payload == Payload(passed: true))
    }

    @Test func decodeExtractsJSONArrayFromMarkdownFence() throws {
        let text = """
        ```json
        [
          \"a\",
          \"b\"
        ]
        ```
        """

        let payload = try ModelResponseJSONExtractor.decode([String].self, from: text)

        #expect(payload == ["a", "b"])
    }

    @Test func detectsStructuredJSONInsideMarkdownFence() {
        let text = """
        ```json
        {
          \"status\": \"ok\"
        }
        ```
        """

        #expect(ModelResponseJSONExtractor.containsJSONObjectOrArray(in: text) == true)
    }
}