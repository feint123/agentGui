import Foundation

enum BackgroundTaskSchedulingNotifications {
    static let refreshRequested = Notification.Name("BackgroundTaskScheduling.refreshRequested")

    static func postRefresh(on notificationCenter: NotificationCenter = .default) {
        notificationCenter.post(name: refreshRequested, object: nil)
    }
}