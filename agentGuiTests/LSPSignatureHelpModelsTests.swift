// agentGuiTests/LSPSignatureHelpModelsTests.swift
import Testing
@testable import agentGui

@Suite("LSPSignatureHelpModels")
struct LSPSignatureHelpModelsTests {

    // MARK: - LSPParameterLabelOffset

    @Test func parameterLabelOffset_arrayForm_returnsCorrectRange() {
        let param = LSPParameterInformation(
            label: .range(5, 10),
            documentation: nil
        )
        guard case .range(let start, let end) = param.label else {
            Issue.record("expected .range")
            return
        }
        #expect(start == 5)
        #expect(end == 10)
    }

    @Test func parameterLabelOffset_stringForm_returnsString() {
        let param = LSPParameterInformation(
            label: .text("value"),
            documentation: nil
        )
        guard case .text(let s) = param.label else {
            Issue.record("expected .text")
            return
        }
        #expect(s == "value")
    }

    // MARK: - LSPSignatureInformation

    @Test func signatureInformation_decodeFromDict_fieldsCorrect() throws {
        let raw: [String: Any] = [
            "label": "print(_ value: Any)",
            "documentation": ["kind": "markdown", "value": "Prints to stdout."],
            "parameters": [
                ["label": "value", "documentation": "The item to print."]
            ],
            "activeParameter": 0
        ]
        let sig = try LSPSignatureInformation(raw: raw)
        #expect(sig.label == "print(_ value: Any)")
        #expect(sig.parameters.count == 1)
        #expect(sig.activeParameter == 0)
    }

    // MARK: - LSPSignatureHelp

    @Test func signatureHelp_emptySignatures_isInvalid() {
        let help = LSPSignatureHelp(signatures: [], activeSignature: 0, activeParameter: 0)
        #expect(!help.isValid)
    }

    @Test func signatureHelp_nonEmptySignatures_isValid() {
        let sig = LSPSignatureInformation(
            label: "foo(a: Int)",
            documentation: nil,
            parameters: [],
            activeParameter: nil
        )
        let help = LSPSignatureHelp(signatures: [sig], activeSignature: 0, activeParameter: 0)
        #expect(help.isValid)
    }

    @Test func signatureHelp_activeParameterResolution_usesSignatureLevelFirst() {
        let sig = LSPSignatureInformation(
            label: "foo(a: Int, b: String)",
            documentation: nil,
            parameters: [
                LSPParameterInformation(label: .text("a: Int"), documentation: nil),
                LSPParameterInformation(label: .text("b: String"), documentation: nil)
            ],
            activeParameter: 1   // signature-level override
        )
        let help = LSPSignatureHelp(signatures: [sig], activeSignature: 0, activeParameter: 0)
        // signature-level activeParameter wins over top-level
        #expect(help.resolvedActiveParameter(for: 0) == 1)
    }

    @Test func signatureHelp_activeParameterResolution_fallsBackToTopLevel() {
        let sig = LSPSignatureInformation(
            label: "foo(a: Int, b: String)",
            documentation: nil,
            parameters: [
                LSPParameterInformation(label: .text("a: Int"), documentation: nil),
                LSPParameterInformation(label: .text("b: String"), documentation: nil)
            ],
            activeParameter: nil   // no signature-level value
        )
        let help = LSPSignatureHelp(signatures: [sig], activeSignature: 0, activeParameter: 1)
        #expect(help.resolvedActiveParameter(for: 0) == 1)
    }
}

// MARK: - LSPClient signatureHelp parsing

@Suite("LSPClient signatureHelp parsing")
struct LSPClientSignatureHelpParsingTests {

    @Test func parse_pylspStyleResponse_returnsValidHelp() throws {
        let raw: [String: Any] = [
            "signatures": [
                [
                    "label": "print(*objects, sep=' ', end='\\n', file=None, flush=False)",
                    "parameters": [
                        ["label": "objects"],
                        ["label": "sep"],
                        ["label": "end"],
                        ["label": "file"],
                        ["label": "flush"]
                    ]
                ]
            ],
            "activeSignature": 0,
            "activeParameter": 1
        ]
        let help = try LSPClientSignatureHelpParser.parse(raw: raw)
        #expect(help?.isValid == true)
        #expect(help?.signatures[0].parameters.count == 5)
        #expect(help?.resolvedActiveParameter(for: 0) == 1)
    }

    @Test func parse_nullResult_returnsNil() throws {
        let help = try LSPClientSignatureHelpParser.parse(raw: nil)
        #expect(help == nil)
    }

    @Test func parse_emptySignatures_returnsNil() throws {
        let raw: [String: Any] = ["signatures": [], "activeSignature": 0, "activeParameter": 0]
        let help = try LSPClientSignatureHelpParser.parse(raw: raw)
        #expect(help == nil)   // isValid == false → 归一为 nil
    }
}
