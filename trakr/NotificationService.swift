import Foundation
import UserNotifications

/// Handles notification permissions and sending notifications
class NotificationService {

    // MARK: - Singleton

    static let shared = NotificationService()

    // MARK: - Initialization

    private init() {}

    // MARK: - Public Methods

    func requestPermissions() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) {
            _, error in
            if let error = error {
                print("Notification permission error: \(error)")
            }
        }
    }

    func sendDailyGoalNotification(formattedActiveTime: String) {
        let content = UNMutableNotificationContent()
        content.title = "🎉 Daily Goal Reached!"
        content.body = "You've completed \(formattedActiveTime) of work today. Great job!"
        content.sound = .defaultCritical
        content.interruptionLevel = .timeSensitive

        let request = UNNotificationRequest(
            identifier: "dailyGoalReached", content: content, trigger: nil)

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("Failed to send notification: \(error)")
            }
        }
    }
}

