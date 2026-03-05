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

    @State private var claudeService = ClaudeService()

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            AppSettings.self,
            Session.self,
            Message.self,
            ToolCall.self,
        ])

        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

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
                .onAppear {
                    // 从持久化设置加载 API Key
                    let context = sharedModelContainer.mainContext
                    let settings = AppSettings.getOrCreate(in: context)
                    claudeService.configure(apiKey: settings.apiKey, baseURL: settings.baseURL)
                }
        }
        .modelContainer(sharedModelContainer)
    }
}
