//
//  agentGuiApp.swift
//  agentGui
//
//  Created by feint on 2026/2/10.
//

import SwiftUI
import SwiftData

@main
struct agentGuiApp: App {

    init() {
        ConfigDirectoryManager.shared.setup()
    }

    @State private var claudeService = ClaudeService()
    @State private var skillService = SkillService()
    @State private var workflowRuntime: WorkflowRuntime?

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            AppSettings.self,
            Session.self,
            Message.self,
            ToolCall.self,
            AgentRound.self,
            // Workflow orchestration models (Phase 1)
            WorkflowInstance.self,
            WorkflowMessageRecord.self,
            WorkflowArtifactRecord.self,
            WorkflowActivationRecord.self,
        ])

        let storeDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".agentgui")
        try? FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        let storeURL = storeDirectory.appendingPathComponent("default.store")
        let modelConfiguration = ModelConfiguration(schema: schema, url: storeURL)

        do {
            return try ModelContainer(
                for: schema,
                configurations: [modelConfiguration]
            )
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(claudeService)
                .environment(skillService)
                .environment(workflowRuntime ?? WorkflowRuntime(claudeService: claudeService))
                .onAppear {
                    // 从持久化设置加载 API Key
                    let context = sharedModelContainer.mainContext
                    let settings = AppSettings.getOrCreate(in: context)
                    claudeService.configure(apiKey: settings.apiKey, baseURL: settings.baseURL)
                    claudeService.skillService = skillService
                    skillService.loadSkills()
                    let runtime = WorkflowRuntime(claudeService: claudeService)
                    workflowRuntime = runtime
                    claudeService.workflowRuntime = runtime
                }
        }
        .modelContainer(sharedModelContainer)
    }
}
