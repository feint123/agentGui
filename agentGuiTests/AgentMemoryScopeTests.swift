import XCTest
@testable import agentGui

final class AgentMemoryScopeTests: XCTestCase {

    // MARK: - RawValue round-trip（对齐 Claude Code 'user'|'project'|'local'）

    func test_rawValue_user() {
        XCTAssertEqual(AgentMemoryScope(rawValue: "user"), .user)
    }

    func test_rawValue_project() {
        XCTAssertEqual(AgentMemoryScope(rawValue: "project"), .project)
    }

    func test_rawValue_local() {
        XCTAssertEqual(AgentMemoryScope(rawValue: "local"), .local)
    }

    func test_rawValue_unknown_returnsNil() {
        XCTAssertNil(AgentMemoryScope(rawValue: "workspace"))
        XCTAssertNil(AgentMemoryScope(rawValue: "global"))
        XCTAssertNil(AgentMemoryScope(rawValue: ""))
    }

    func test_rawValue_caseSensitive() {
        // rawValue 区分大小写，与 Claude Code 对齐
        XCTAssertNil(AgentMemoryScope(rawValue: "User"))
        XCTAssertNil(AgentMemoryScope(rawValue: "PROJECT"))
    }

    // MARK: - Codable

    func test_codable_roundTrip() throws {
        let scopes: [AgentMemoryScope] = [.user, .project, .local]
        for scope in scopes {
            let encoded = try JSONEncoder().encode(scope)
            let decoded = try JSONDecoder().decode(AgentMemoryScope.self, from: encoded)
            XCTAssertEqual(decoded, scope, "Codable round-trip failed for \(scope)")
        }
    }

    func test_codable_encodeAsString() throws {
        let data = try JSONEncoder().encode(AgentMemoryScope.user)
        let jsonString = String(data: data, encoding: .utf8)!
        XCTAssertEqual(jsonString, "\"user\"")
    }

    // MARK: - Sendable（编译时保证，无运行时断言）
    func test_isSendable() {
        // 编译通过即为通过：AgentMemoryScope: Sendable 合约验证
        let scope: AgentMemoryScope = .project
        let _: @Sendable () -> AgentMemoryScope = { scope }
        _ = scope
    }
}
