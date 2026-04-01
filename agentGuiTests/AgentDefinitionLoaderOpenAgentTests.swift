import XCTest
@testable import agentGui

final class AgentDefinitionLoaderOpenAgentTests: XCTestCase {

    // MARK: - SubagentModelPreference

    func test_modelPreference_rawValueRoundTrip() {
        XCTAssertEqual(SubagentModelPreference(rawValue: "haiku"),   .haiku)
        XCTAssertEqual(SubagentModelPreference(rawValue: "sonnet"),  .sonnet)
        XCTAssertEqual(SubagentModelPreference(rawValue: "opus"),    .opus)
        XCTAssertEqual(SubagentModelPreference(rawValue: "inherit"), .inherit)
        XCTAssertNil(SubagentModelPreference(rawValue: "unknown"))
    }

    func test_effort_rawValueRoundTrip() {
        XCTAssertEqual(SubagentEffort(rawValue: "low"),    .low)
        XCTAssertEqual(SubagentEffort(rawValue: "medium"), .medium)
        XCTAssertEqual(SubagentEffort(rawValue: "high"),   .high)
        XCTAssertNil(SubagentEffort(rawValue: "critical"))
    }

    // MARK: - AgentDefinitionDocument optional fields

    private let minimalFrontmatter = """
        ---
        name: researcher
        display-name: Research Agent
        description: Searches and summarises.
        argument-hint: Describe what to find.
        tools: [read_only_editor]
        max-turns: 20
        user-invocable: false
        subagent-invocable: true
        output-contract: research_report
        ---
        # Role
        You are a researcher.
        """

    func test_documentDefaultsForOptionalFields() throws {
        let loader = AgentDefinitionLoader()
        let doc = try loader.parseDocument(named: "researcher.agent.md", raw: minimalFrontmatter)

        XCTAssertEqual(doc.modelPreference,     .inherit)
        XCTAssertNil(doc.effort)
        XCTAssertFalse(doc.background)
        XCTAssertFalse(doc.omitMainContext)
        XCTAssertNil(doc.initialPrompt)
        XCTAssertNil(doc.criticalReminder)
        XCTAssertNil(doc.color)
        XCTAssertEqual(doc.disallowedToolNames, [])
    }

    func test_documentParsesAllOptionalFields() throws {
        let raw = """
            ---
            name: analyst
            display-name: Analyst
            description: Deep analysis.
            argument-hint: Topic to analyse.
            tools: [read_only_editor]
            max-turns: 10
            user-invocable: false
            subagent-invocable: true
            output-contract: analysis_report
            model-preference: haiku
            effort: high
            background: true
            omit-main-context: true
            initial-prompt: Think carefully before answering.
            critical-reminder: READ-ONLY. Do not edit files.
            color: blue
            disallowed-tools: [bash_write, file_delete]
            ---
            # Role
            You are an analyst.
            """
        let loader = AgentDefinitionLoader()
        let doc = try loader.parseDocument(named: "analyst.agent.md", raw: raw)

        XCTAssertEqual(doc.modelPreference,     .haiku)
        XCTAssertEqual(doc.effort,              .high)
        XCTAssertTrue(doc.background)
        XCTAssertTrue(doc.omitMainContext)
        XCTAssertEqual(doc.initialPrompt,       "Think carefully before answering.")
        XCTAssertEqual(doc.criticalReminder,    "READ-ONLY. Do not edit files.")
        XCTAssertEqual(doc.color,               "blue")
        XCTAssertEqual(doc.disallowedToolNames, ["bash_write", "file_delete"])
    }

    // MARK: - Whitelist removal

    func test_customAgentNameLoadsSuccessfully() throws {
        let loader = AgentDefinitionLoader()
        let doc = try loader.parseDocument(named: "researcher.agent.md", raw: minimalFrontmatter)
        XCTAssertEqual(doc.name, "researcher")
    }

    func test_customOutputContractLoadsSuccessfully() throws {
        let raw = minimalFrontmatter  // output-contract: research_report (非白名单)
        let loader = AgentDefinitionLoader()
        let doc = try loader.parseDocument(named: "researcher.agent.md", raw: raw)
        XCTAssertEqual(doc.outputContract, "research_report")
    }

    func test_existingExploreAgentStillLoads() throws {
        let loader = AgentDefinitionLoader()
        let docs = try loader.loadBuiltInDocuments(from: .main)
        XCTAssertTrue(docs.contains(where: { $0.name == "explore" }))
        XCTAssertTrue(docs.contains(where: { $0.name == "worker" }))
        XCTAssertTrue(docs.contains(where: { $0.name == "verifier" }))
    }

    func test_modelPreferenceField_parsedFromFrontmatter() throws {
        let raw = """
            ---
            name: scout
            display-name: Scout
            description: Scout agent.
            argument-hint: Where to scout.
            tools: [read_only_editor]
            max-turns: 5
            user-invocable: false
            subagent-invocable: true
            output-contract: scout_report
            model-preference: haiku
            ---
            # Role
            Scout.
            """
        let doc = try AgentDefinitionLoader().parseDocument(named: "scout.agent.md", raw: raw)
        XCTAssertEqual(doc.modelPreference, .haiku)
    }

    func test_backgroundField_parsedFromFrontmatter() throws {
        let raw = """
            ---
            name: bg-worker
            display-name: Background Worker
            description: Runs in background.
            argument-hint: Task.
            tools: [read_only_editor]
            max-turns: 5
            user-invocable: false
            subagent-invocable: true
            output-contract: bg_result
            background: true
            ---
            # Role
            Background.
            """
        let doc = try AgentDefinitionLoader().parseDocument(named: "bg-worker.agent.md", raw: raw)
        XCTAssertTrue(doc.background)
    }

    func test_disallowedToolsField_parsedFromFrontmatter() throws {
        let raw = """
            ---
            name: safe-scout
            display-name: Safe Scout
            description: Read-only scout.
            argument-hint: What to find.
            tools: [read_only_editor]
            max-turns: 5
            user-invocable: false
            subagent-invocable: true
            output-contract: scout_report
            disallowed-tools: [bash_exec, file_write]
            ---
            # Role
            Safe.
            """
        let doc = try AgentDefinitionLoader().parseDocument(named: "safe-scout.agent.md", raw: raw)
        XCTAssertEqual(doc.disallowedToolNames, ["bash_exec", "file_write"])
    }

    // MARK: - AgentRuntimeDefinition generic default

    func test_customAgentMakesRuntimeDefinitionWithDefaultArtifacts() throws {
        let loader = AgentDefinitionLoader()
        let doc = try loader.parseDocument(named: "researcher.agent.md", raw: minimalFrontmatter)
        let runtime = try AgentRuntimeDefinition.make(from: doc)

        XCTAssertEqual(runtime.name, "researcher")
        XCTAssertEqual(runtime.outputContract, "research_report")
        XCTAssertEqual(runtime.readableArtifacts, [])
        XCTAssertEqual(runtime.writableArtifacts, [])
    }

    func test_customAgentRuntimeDefinitionPropagatesModelPreference() throws {
        let raw = """
            ---
            name: haiku-agent
            display-name: Haiku Agent
            description: Uses haiku model.
            argument-hint: Task.
            tools: [read_only_editor]
            max-turns: 5
            user-invocable: false
            subagent-invocable: true
            output-contract: haiku_report
            model-preference: haiku
            ---
            # Role
            Haiku.
            """
        let doc = try AgentDefinitionLoader().parseDocument(named: "haiku-agent.agent.md", raw: raw)
        let runtime = try AgentRuntimeDefinition.make(from: doc)
        XCTAssertEqual(runtime.modelPreference, .haiku)
    }

    func test_existingExploreRuntimeDefinitionPreservesArtifacts() throws {
        let loader = AgentDefinitionLoader()
        let docs = try loader.loadBuiltInDocuments(from: .main)
        let exploreDoc = try XCTUnwrap(docs.first(where: { $0.name == "explore" }))
        let runtime = try AgentRuntimeDefinition.make(from: exploreDoc)

        XCTAssertEqual(runtime.readableArtifacts,        [.plan])
        XCTAssertEqual(runtime.writableArtifacts,        [.explorationReport])
        XCTAssertEqual(runtime.primaryOutputArtifactKind, .explorationReport)
    }

    // MARK: - WorkflowRoleDefinition field propagation

    func test_workflowRoleDefinitionPropagatesModelPreference() throws {
        let raw = """
            ---
            name: haiku-role
            display-name: Haiku Role
            description: Uses haiku.
            argument-hint: Task.
            tools: [read_only_editor]
            max-turns: 5
            user-invocable: false
            subagent-invocable: true
            output-contract: haiku_report
            model-preference: haiku
            ---
            # Role
            Haiku.
            """
        let doc     = try AgentDefinitionLoader().parseDocument(named: "haiku-role.agent.md", raw: raw)
        let runtime = try AgentRuntimeDefinition.make(from: doc)
        let role    = runtime.workflowRoleDefinition

        XCTAssertEqual(role.modelPreference,     .haiku)
        XCTAssertFalse(role.omitMainContext)
        XCTAssertNil(role.criticalReminder)
        XCTAssertEqual(role.disallowedToolNames, [])
    }

    func test_workflowRoleDefinitionPropagatesOmitMainContext() throws {
        let raw = """
            ---
            name: lean-explorer
            display-name: Lean Explorer
            description: Lean explore.
            argument-hint: What to find.
            tools: [read_only_editor]
            max-turns: 10
            user-invocable: false
            subagent-invocable: true
            output-contract: exploration_result
            omit-main-context: true
            critical-reminder: READ ONLY. Do not write files.
            ---
            # Role
            Lean.
            """
        let doc     = try AgentDefinitionLoader().parseDocument(named: "lean-explorer.agent.md", raw: raw)
        let runtime = try AgentRuntimeDefinition.make(from: doc)
        let role    = runtime.workflowRoleDefinition

        XCTAssertTrue(role.omitMainContext)
        XCTAssertEqual(role.criticalReminder, "READ ONLY. Do not write files.")
    }

    // MARK: - Backward compatibility

    func test_existingAgentsHaveDefaultOptionalFieldValues() throws {
        let catalog = AgentCatalog.shared
        let explore  = try XCTUnwrap(catalog.find(named: "explore"))
        let worker   = try XCTUnwrap(catalog.find(named: "worker"))
        let verifier = try XCTUnwrap(catalog.find(named: "verifier"))

        for runtime in [explore, worker, verifier] {
            XCTAssertEqual(runtime.modelPreference, .inherit,
                           "\(runtime.name) modelPreference should default to .inherit")
            XCTAssertNil(runtime.effort,
                         "\(runtime.name) effort should default to nil")
            XCTAssertFalse(runtime.background,
                           "\(runtime.name) background should default to false")
            XCTAssertFalse(runtime.omitMainContext,
                           "\(runtime.name) omitMainContext should default to false")
            XCTAssertNil(runtime.initialPrompt)
            XCTAssertNil(runtime.criticalReminder)
            XCTAssertNil(runtime.color)
            XCTAssertEqual(runtime.disallowedToolNames, [])
        }
    }
}
