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

    private static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

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
            WritingProject.self,
            StoryCharacterProfile.self,
            StoryWorldRule.self,
            StoryLocationProfile.self,
            StoryStyleProfile.self,
            StoryChapterRecord.self,
            StorySceneRecord.self,
            StoryTimelineEvent.self,
            StoryForeshadowItem.self,
            StoryContinuityIssue.self,
            // Workflow orchestration models (Phase 1)
            WorkflowInstance.self,
            WorkflowMessageRecord.self,
            WorkflowArtifactRecord.self,
            WorkflowActivationRecord.self,
        ])

        let modelConfiguration: ModelConfiguration
        if Self.isRunningTests {
            modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        } else {
            let storeDirectory = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".agentgui")
            try? FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
            let storeURL = storeDirectory.appendingPathComponent("default.store")
            modelConfiguration = ModelConfiguration(schema: schema, url: storeURL)
        }

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
                    claudeService.applyConnectionSettings(settings)
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
