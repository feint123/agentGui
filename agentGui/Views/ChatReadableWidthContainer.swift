import SwiftUI

struct ChatReadableWidthContainer<Content: View>: View {
    @ViewBuilder private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .frame(maxWidth: ChatSurfaceLayoutMetrics.desktopConversationMaxWidth)
            .frame(maxWidth: .infinity, alignment: .center)
    }
}