import XCTest
@testable import agentGui

final class PlanAgentDefinitionTests: XCTestCase {

    // MARK: - plan.agent.md 文件加载

    func test_planAgentIsLoadedByBuiltInLoader() throws {
        let docs = try AgentDefinitionLoader().loadBuiltInDocuments(from: .main)
        XCTAssertTrue(docs.contains(where: { $0.name == "plan" }),
                      "built-in agents 必须包含 plan 代理")
    }

    func test_planAgentFrontmatterFields() throws {
        let docs = try AgentDefinitionLoader().loadBuiltInDocuments(from: .main)
        let doc = try XCTUnwrap(docs.first(where: { $0.name == "plan" }))

        XCTAssertEqual(doc.displayName,      "架构规划者")
        XCTAssertEqual(doc.outputContract,   "plan_report")
        XCTAssertEqual(doc.modelPreference,  .inherit,
                       "plan 代理应继承主代理模型（full capability）")
        XCTAssertTrue(doc.omitMainContext,   "plan 代理应跳过主代理上下文注入")
        XCTAssertFalse(doc.userInvocable,   "plan 代理不应由用户直接调用")
        XCTAssertTrue(doc.subagentInvocable,"plan 代理应可由子代理调用")
        // tools 至少包含 read_only_editor
        XCTAssertTrue(doc.toolGroupNames.contains("read_only_editor"))
        // 不应包含写入工具组
        XCTAssertFalse(doc.toolGroupNames.contains("read_write_editor"))
        XCTAssertFalse(doc.toolGroupNames.contains("shell"))
        // body 不为空
        XCTAssertFalse(doc.body.isEmpty)
    }

    // MARK: - AgentRuntimeDefinition.make 对 plan 的 artifact 绑定

    func test_planRuntimeDefinitionArtifacts() throws {
        let docs = try AgentDefinitionLoader().loadBuiltInDocuments(from: .main)
        let doc = try XCTUnwrap(docs.first(where: { $0.name == "plan" }))
        let runtime = try AgentRuntimeDefinition.make(from: doc)

        // plan 代理可以读取 explorationReport
        XCTAssertTrue(runtime.readableArtifacts.contains(.explorationReport))
        // plan 代理产出 .plan 工产物
        XCTAssertTrue(runtime.writableArtifacts.contains(.plan))
        XCTAssertEqual(runtime.primaryOutputArtifactKind, .plan)
    }

    func test_planRuntimeDefinitionToolGrants_noWriteAccess() throws {
        let docs = try AgentDefinitionLoader().loadBuiltInDocuments(from: .main)
        let doc = try XCTUnwrap(docs.first(where: { $0.name == "plan" }))
        let runtime = try AgentRuntimeDefinition.make(from: doc)

        let hasWrite = runtime.toolGrants.contains {
            $0.toolGroupID == .readWriteEditor || $0.toolGroupID == .shell
        }
        XCTAssertFalse(hasWrite, "plan 代理不应有写文件或 shell 权限")
    }

    // MARK: - 现有三个代理不受影响（回归）

    func test_existingAgentsUnaffected() throws {
        let docs = try AgentDefinitionLoader().loadBuiltInDocuments(from: .main)
        let names = docs.map(\.name)
        XCTAssertTrue(names.contains("explore"))
        XCTAssertTrue(names.contains("worker"))
        XCTAssertTrue(names.contains("verifier"))
        // 共计 4 个内置代理
        XCTAssertEqual(names.filter { ["explore","worker","verifier","plan"].contains($0) }.count, 4)
    }

    // MARK: - WorkflowRoleDefinition 字段传播

    func test_planWorkflowRoleDefinition_propagatesOmitMainContext() throws {
        let docs = try AgentDefinitionLoader().loadBuiltInDocuments(from: .main)
        let doc = try XCTUnwrap(docs.first(where: { $0.name == "plan" }))
        let runtime = try AgentRuntimeDefinition.make(from: doc)
        let role = runtime.workflowRoleDefinition

        XCTAssertTrue(role.omitMainContext)
        XCTAssertEqual(role.modelPreference, .inherit)
        XCTAssertEqual(role.primaryOutputArtifactKind, .plan)
    }

    // MARK: - AgentCatalog 发现

    func test_agentCatalogFindsplan() throws {
        XCTAssertNotNil(AgentCatalog.shared.find(named: "plan"),
                        "AgentCatalog.shared 必须能按名称找到 plan 代理")
    }

    func test_agentCatalog_subagentInvocableIncludes_plan() throws {
        let names = AgentCatalog.shared.subagentInvocableAgents.map(\.name)
        XCTAssertTrue(names.contains("plan"))
    }

    // MARK: - 系统提示内包含关键约束文本

    func test_planSystemPromptContainsReadOnlyWarning() throws {
        let docs = try AgentDefinitionLoader().loadBuiltInDocuments(from: .main)
        let doc = try XCTUnwrap(docs.first(where: { $0.name == "plan" }))

        let prompt = doc.body.lowercased()
        // 必须含只读约束声明
        XCTAssertTrue(prompt.contains("read-only") || prompt.contains("read only"),
                      "plan 代理 body 必须包含 READ-ONLY 声明")
        // 必须含 critical files 输出要求
        XCTAssertTrue(prompt.contains("critical files"),
                      "plan 代理 body 必须要求输出 Critical Files for Implementation")
    }

    // MARK: - 排序稳定性

    func test_planAgentIsLastInBuiltInSortOrder() throws {
        let docs = try AgentDefinitionLoader().loadBuiltInDocuments(from: .main)
        let names = docs.map(\.name)
        // explore worker verifier plan 的相对顺序应稳定
        let exploreIdx  = try XCTUnwrap(names.firstIndex(of: "explore"))
        let workerIdx   = try XCTUnwrap(names.firstIndex(of: "worker"))
        let verifierIdx = try XCTUnwrap(names.firstIndex(of: "verifier"))
        let planIdx     = try XCTUnwrap(names.firstIndex(of: "plan"))

        XCTAssertLessThan(exploreIdx,  workerIdx)
        XCTAssertLessThan(workerIdx,   verifierIdx)
        XCTAssertLessThan(verifierIdx, planIdx)
    }

    // MARK: - WorkflowRoleDefinition 静态属性

    func test_workflowRoleDefinition_planStaticProperty() {
        let role = WorkflowRoleDefinition.plan
        XCTAssertEqual(role.name, "plan")
        XCTAssertEqual(role.primaryOutputArtifactKind, .plan)
    }

    func test_workflowRoleDefinition_plannerAliasPoinsToPlan() {
        XCTAssertEqual(WorkflowRoleDefinition.planner.name, "plan")
    }
}
