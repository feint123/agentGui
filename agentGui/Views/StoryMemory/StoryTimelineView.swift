import SwiftUI

struct StoryTimelineView: View {
    let timelineTitles: [String]

    var body: some View {
        if timelineTitles.isEmpty {
            ContentUnavailableView("暂无时间线事件", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90")
        } else {
            List(timelineTitles, id: \ .self) { title in
                Label(title, systemImage: "clock")
            }
            .listStyle(.plain)
        }
    }
}