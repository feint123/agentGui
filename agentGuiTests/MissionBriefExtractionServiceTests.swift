import Foundation
import Testing
@testable import agentGui

struct MissionBriefExtractionServiceTests {

    // MARK: - Stub

    struct StubSuccessService: MissionBriefExtractionService {
        let result: MissionBriefExtractionResult
        func extract(from rawInput: String) async throws -> MissionBriefExtractionResult {
            result
        }
    }

    struct StubFailService: MissionBriefExtractionService {
        func extract(from rawInput: String) async throws -> MissionBriefExtractionResult {
            throw URLError(.timedOut)
        }
    }

    @Test
    func stubSuccessReturnsExpectedResult() async throws {
        let expected = MissionBriefExtractionResult(
            objective: "为 ACP 修复并发问题",
            constraints: ["仅修改 Swift 文件"],
            acceptanceCriteria: ["Focused tests 全通过"],
            suggestedMode: .executionDelivery
        )
        let service: any MissionBriefExtractionService = StubSuccessService(result: expected)
        let result = try await service.extract(from: "修复 ACP 并发问题，只改 Swift 文件，测试绿")
        #expect(result.objective == expected.objective)
        #expect(result.constraints == expected.constraints)
        #expect(result.acceptanceCriteria == expected.acceptanceCriteria)
        #expect(result.suggestedMode == .executionDelivery)
    }

    @Test
    func stubFailPropagatesError() async {
        let service: any MissionBriefExtractionService = StubFailService()
        do {
            _ = try await service.extract(from: "some input")
            #expect(Bool(false), "应当抛出错误")
        } catch {
            #expect((error as? URLError)?.code == .timedOut)
        }
    }

    // JSON 解析逻辑测试（直接测 parseExtractionJSON）
    @Test
    func parsesBriefExtractionJSON() throws {
        let json = """
        {
          "objective": "统一修复 ACP team",
          "constraints": ["仅修改 Swift 文件", "保持 focused tests"],
          "acceptanceCriteria": ["Mission Header 回显 brief"],
          "suggestedMode": "executionDelivery"
        }
        """
        let result = BuiltInMissionBriefExtractionService.parseExtractionJSON(json)
        #expect(result?.objective == "统一修复 ACP team")
        #expect(result?.constraints == ["仅修改 Swift 文件", "保持 focused tests"])
        #expect(result?.acceptanceCriteria == ["Mission Header 回显 brief"])
        #expect(result?.suggestedMode == .executionDelivery)
    }

    @Test
    func parsesBriefExtractionJSONWithCodeFence() throws {
        let json = """
        ```json
        {
          "objective": "修复 ACP",
          "constraints": [],
          "acceptanceCriteria": [],
          "suggestedMode": "creativeExploration"
        }
        ```
        """
        let result = BuiltInMissionBriefExtractionService.parseExtractionJSON(json)
        #expect(result?.objective == "修复 ACP")
        #expect(result?.suggestedMode == .creativeExploration)
    }

    @Test
    func parseReturnsNilForMalformedJSON() {
        let result = BuiltInMissionBriefExtractionService.parseExtractionJSON("not json")
        #expect(result == nil)
    }
}
