import Foundation

enum ModelResponseJSONExtractor {
    enum ExtractionError: Error, Equatable {
        case noJSONCandidate
    }

    static func decode<T: Decodable>(
        _ type: T.Type,
        from text: String,
        using decoder: JSONDecoder = JSONDecoder(),
        salvage: ((String) -> T?)? = nil
    ) throws -> T {
        let candidates = jsonCandidates(from: text)
        var lastError: Error?

        for candidate in candidates {
            guard let data = candidate.data(using: .utf8) else { continue }
            do {
                return try decoder.decode(type, from: data)
            } catch {
                lastError = error
            }
        }

        if let salvage, let recovered = salvage(text) {
            return recovered
        }

        throw lastError ?? ExtractionError.noJSONCandidate
    }

    static func decodeIfPresent<T: Decodable>(
        _ type: T.Type,
        from text: String,
        using decoder: JSONDecoder = JSONDecoder(),
        salvage: ((String) -> T?)? = nil
    ) -> T? {
        try? decode(type, from: text, using: decoder, salvage: salvage)
    }

    static func containsJSONObjectOrArray(in text: String) -> Bool {
        !jsonCandidates(from: text).isEmpty
    }

    static func jsonCandidates(from text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let unfenced = stripMarkdownFences(trimmed)
        var candidates: [String] = []

        appendUnique(trimmed, to: &candidates)
        appendUnique(unfenced, to: &candidates)
        appendUnique(extractFirstJSONObject(from: trimmed), to: &candidates)
        appendUnique(extractFirstJSONArray(from: trimmed), to: &candidates)
        appendUnique(extractFirstJSONObject(from: unfenced), to: &candidates)
        appendUnique(extractFirstJSONArray(from: unfenced), to: &candidates)

        return candidates
    }

    static func stripMarkdownFences(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.hasPrefix("```") {
            if let newline = result.firstIndex(of: "\n") {
                result = String(result[result.index(after: newline)...])
            }
            if result.hasSuffix("```") {
                result = String(result.dropLast(3))
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func extractFirstJSONObject(from text: String) -> String? {
        extractFirstJSONValue(from: text, opening: "{", closing: "}")
    }

    static func extractFirstJSONArray(from text: String) -> String? {
        extractFirstJSONValue(from: text, opening: "[", closing: "]")
    }

    private static func appendUnique(_ candidate: String?, to candidates: inout [String]) {
        guard let candidate,
              !candidate.isEmpty,
              !candidates.contains(candidate) else { return }
        candidates.append(candidate)
    }

    private static func extractFirstJSONValue(from text: String, opening: Character, closing: Character) -> String? {
        guard let startIndex = text.firstIndex(of: opening) else { return nil }

        var depth = 0
        var isInsideString = false
        var isEscaping = false

        for index in text[startIndex...].indices {
            let character = text[index]

            if isEscaping {
                isEscaping = false
                continue
            }

            if character == "\\" {
                isEscaping = true
                continue
            }

            if character == "\"" {
                isInsideString.toggle()
                continue
            }

            if isInsideString {
                continue
            }

            if character == opening {
                depth += 1
            } else if character == closing {
                depth -= 1
                if depth == 0 {
                    return String(text[startIndex...index])
                }
            }
        }

        return nil
    }
}