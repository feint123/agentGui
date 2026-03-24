import SpriteKit
import SwiftUI

struct AgentStudioView: View {
    let projection: AgentStudioProjection
    let isScenePaused: Bool

    @State private var scene = AgentStudioScene()

    var body: some View {
        SpriteView(scene: scene, options: [.allowsTransparency])
            .background(
                LinearGradient(
                    colors: [
                        Color(red: 0.98, green: 0.97, blue: 0.92),
                        Color(red: 0.91, green: 0.95, blue: 0.99)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .clipShape(.rect(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.black.opacity(0.08), lineWidth: 1)
            )
            .accessibilityIdentifier("window.agentStudio.scene")
            .onAppear {
                scene.applyProjection(projection)
                scene.setRenderingPaused(isScenePaused)
            }
            .onChange(of: projection) { _, newProjection in
                scene.applyProjection(newProjection)
            }
            .onChange(of: isScenePaused) { _, newValue in
                scene.setRenderingPaused(newValue)
            }
    }
}