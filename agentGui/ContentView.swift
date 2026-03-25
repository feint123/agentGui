//
//  ContentView.swift
//  agentGui
//
//  Created by feint on 2026/2/10.
//

import SwiftUI
import SwiftData

/// 应用主视图
struct ContentView: View {

    private let launchOptions = TestLaunchOptions.current
    @State private var commandPaletteSceneID: UUID
    @State private var commandPaletteViewModel: CommandPaletteViewModel
    @State private var persistenceCoordinator = PersistenceCoordinator.shared
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(ReliabilityCenterViewModel.self) private var reliabilityCenterViewModel

    init() {
        let sceneID = UUID()
        _commandPaletteSceneID = State(initialValue: sceneID)
        _commandPaletteViewModel = State(initialValue: CommandPaletteViewModel(sceneID: sceneID))
    }

    var body: some View {
        WorkbenchShellView(sceneID: commandPaletteSceneID)
        .frame(minWidth: 900, minHeight: 600)
        .environment(commandPaletteViewModel)
        .environment(persistenceCoordinator)
        .onAppear(perform: synchronizeOnboardingWindow)
        .onChange(of: launchReadiness.isReadyForFirstMessage) { _, _ in
            synchronizeOnboardingWindow()
        }
        .alert(
            "保存失败",
            isPresented: Binding(
                get: { persistenceCoordinator.lastFailure != nil },
                set: { if !$0 { persistenceCoordinator.dismissFailure() } }
            )
        ) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(persistenceCoordinator.lastFailureSummary ?? "本次变更未成功保存。")
        }
    }

    private var launchReadiness: LaunchReadinessStatus {
        LaunchReadinessEvaluator.evaluate(settings: AppSettings.getOrCreate(in: modelContext, persistenceCoordinator: persistenceCoordinator))
    }

    private func synchronizeOnboardingWindow() {
        if launchOptions.suppressOnboarding {
            dismissWindow(id: OnboardingWindowScene.id)
            return
        }

        if launchReadiness.isReadyForFirstMessage {
            dismissWindow(id: OnboardingWindowScene.id)
        } else {
            DispatchQueue.main.async {
                openWindow(id: OnboardingWindowScene.id)
            }
        }
    }
}

#Preview {
    ContentView()
}
