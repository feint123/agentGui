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

    @Test func reflectionParsingRecoversFromMissingArrayCloserBeforeNextKey() {
        let text = """
        ```json
        {
          "confidence": 0.95,
          "concerns": [
            "Syntax error in user query: 'lsp' appears as a trailing token with no clear verb, making the intent ambiguous.",
            "User likely meant 'is this file correct' or 'use LSP to check', but the parser could not resolve the command."
          "suggestedFixes": [
            "Interpret the intent as a request to validate the file using LSP diagnostics and execute that.",
            "Ask the user to clarify the command: 'Do you want LSP diagnostics for this file?'"
          ],
          "shouldRetry": true
        }
        ```
        """

        let reflection = ReflectionJSONDecoder.parse(text: text, threshold: 0.99)

        #expect(reflection?.confidence == 0.95)
        #expect(reflection?.concerns.count == 2)
        #expect(reflection?.suggestedFixes.count == 2)
        #expect(reflection?.shouldRetry == true)
    }
}