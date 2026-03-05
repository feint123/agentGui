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
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            AgentConfiguration.self,
            AppSettings.self,
            Session.self,
            Message.self,
            ToolCall.self,
            PermissionRequest.self,
        ])

        // 配置索引以优化查询性能
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
        }
        .modelContainer(sharedModelContainer)
    }
}
