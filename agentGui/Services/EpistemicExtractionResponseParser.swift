import Foundation

struct EpistemicExtractionResponseParser {
    func parse(_ text: String) throws -> EpistemicExtractionOutput {
        try ModelResponseJSONExtractor.decode(EpistemicExtractionOutput.self, from: text)
    }
}