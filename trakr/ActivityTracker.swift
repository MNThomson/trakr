import Foundation
import IOKit.pwr_mgt
import Quartz
import UserNotifications

class ActivityTracker: ObservableObject {

    // MARK: - Constants

    private enum Keys {
        static let activeSeconds = "activeSeconds"
        static let lastActiveDate = "lastActiveDate"
        static let workStartTime = "workStartTime"
        static let idleThreshold = "idleThreshold"
        static let targetWorkDaySeconds = "targetWorkDaySeconds"
        static let dailyGoalNotificationSent = "dailyGoalNotificationSent"
    }

    private enum Defaults {
        static let idleThreshold: TimeInterval = 120
        static let targetWorkDaySeconds = 8 * 3600
        static let workDayStartHour = 4
        static let saveInterval = 30
    }

    private static let trackedEventTypes: [CGEventType] = [
        .mouseMoved,
        .keyDown,
        .leftMouseDown,
        .scrollWheel,
    ]

    // MARK: - Singleton

    static let shared = ActivityTracker()

    // MARK: - Published Properties

    @Published private(set) var activeSeconds: Int = 0
    @Published private(set) var workStartTime: Date?
    @Published private(set) var isCurrentlyActive: Bool = false
    @Published var targetWorkDaySeconds: Int {
        didSet {
            UserDefaults.standard.set(targetWorkDaySeconds, forKey: Keys.targetWorkDaySeconds)
        }
    }

    // MARK: - Properties

    var idleThreshold: TimeInterval {
        didSet { UserDefaults.standard.set(idleThreshold, forKey: Keys.idleThreshold) }
    }

    private var timer: Timer?
    private var dailyGoalNotificationSent = false

    private lazy var timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter
    }()

    // MARK: - Computed Properties

    var formattedActiveTime: String {
        let hours = activeSeconds / 3600
        let minutes = (activeSeconds % 3600) / 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }

    var formattedWorkStartTime: String? {
        workStartTime.map { timeFormatter.string(from: $0) }
    }

    var formattedEstimatedFinishTime: String? {
        guard workStartTime != nil else { return nil }
        let remainingSeconds = max(0, targetWorkDaySeconds - activeSeconds)
        let estimatedFinish = Date().addingTimeInterval(TimeInterval(remainingSeconds))
        return timeFormatter.string(from: estimatedFinish)
    }

    // MARK: - Initialization

    private init() {
        let savedIdleThreshold = UserDefaults.standard.double(forKey: Keys.idleThreshold)
        idleThreshold = savedIdleThreshold > 0 ? savedIdleThreshold : Defaults.idleThreshold

        let savedTargetSeconds = UserDefaults.standard.integer(forKey: Keys.targetWorkDaySeconds)
        targetWorkDaySeconds =
            savedTargetSeconds > 0 ? savedTargetSeconds : Defaults.targetWorkDaySeconds

        loadState()
        requestNotificationPermissions()
        startTracking()
    }

    deinit {
        timer?.invalidate()
    }

    // MARK: - Public Methods

    func saveState() {
        UserDefaults.standard.set(activeSeconds, forKey: Keys.activeSeconds)
        UserDefaults.standard.set(Date(), forKey: Keys.lastActiveDate)
        if let startTime = workStartTime {
            UserDefaults.standard.set(startTime, forKey: Keys.workStartTime)
        }
    }

    // MARK: - State Management

    private func loadState() {
        guard let lastDate = UserDefaults.standard.object(forKey: Keys.lastActiveDate) as? Date
        else {
            resetToInitialState()
            return
        }

        if isSameWorkDay(lastDate, as: Date()) {
            activeSeconds = UserDefaults.standard.integer(forKey: Keys.activeSeconds)
            workStartTime = UserDefaults.standard.object(forKey: Keys.workStartTime) as? Date
            dailyGoalNotificationSent = UserDefaults.standard.bool(
                forKey: Keys.dailyGoalNotificationSent)
        } else {
            resetForNewWorkDay()
        }
    }

    private func resetToInitialState() {
        activeSeconds = 0
        workStartTime = nil
        dailyGoalNotificationSent = false
    }

    private func resetForNewWorkDay() {
        resetToInitialState()
        UserDefaults.standard.set(false, forKey: Keys.dailyGoalNotificationSent)
        saveState()
    }

    // MARK: - Activity Tracking

    private func startTracking() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.checkActivity()
        }
        RunLoop.current.add(timer!, forMode: .common)
    }

    private func checkActivity() {
        let now = Date()

        if let lastDate = UserDefaults.standard.object(forKey: Keys.lastActiveDate) as? Date,
            !isSameWorkDay(lastDate, as: now)
        {
            resetForNewWorkDay()
        }

        let isInputActive = getSystemIdleTime() < idleThreshold
        let hasPowerAssertion = hasActivePowerAssertions()
        isCurrentlyActive = isInputActive || hasPowerAssertion
        guard isCurrentlyActive else { return }

        if workStartTime == nil && isAfterWorkDayStart(now) {
            workStartTime = now
            saveState()
        }

        activeSeconds += 1

        if activeSeconds >= targetWorkDaySeconds && !dailyGoalNotificationSent {
            sendDailyGoalNotification()
        }

        if activeSeconds % Defaults.saveInterval == 0 {
            saveState()
        }
    }

    private func getSystemIdleTime() -> TimeInterval {
        Self.trackedEventTypes
            .map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }
            .min() ?? .infinity
    }

    private func hasActivePowerAssertions() -> Bool {
        var assertionsStatus: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsStatus(&assertionsStatus) == kIOReturnSuccess,
            let dict = assertionsStatus?.takeRetainedValue() as? [String: Int]
        else {
            return false
        }

        // PreventUserIdleDisplaySleep is created by apps like Zoom, video players
        // (PreventUserIdleSystemSleep is always active from powerd when display is on, so we skip it)
        let activeTypes = [
            "PreventUserIdleDisplaySleep",
            "NoDisplaySleepAssertion",
        ]

        return activeTypes.contains { dict[$0] ?? 0 > 0 }
    }

    // MARK: - Work Day Logic

    private func isSameWorkDay(_ date1: Date, as date2: Date) -> Bool {
        let calendar = Calendar.current
        let adjusted1 = calendar.date(
            byAdding: .hour, value: -Defaults.workDayStartHour, to: date1)!
        let adjusted2 = calendar.date(
            byAdding: .hour, value: -Defaults.workDayStartHour, to: date2)!
        return calendar.isDate(adjusted1, inSameDayAs: adjusted2)
    }

    private func isAfterWorkDayStart(_ date: Date) -> Bool {
        Calendar.current.component(.hour, from: date) >= Defaults.workDayStartHour
    }

    // MARK: - Notifications

    private func requestNotificationPermissions() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) {
            _, error in
            if let error = error {
                print("Notification permission error: \(error)")
            }
        }
    }

    private func sendDailyGoalNotification() {
        guard !dailyGoalNotificationSent else { return }

        dailyGoalNotificationSent = true
        UserDefaults.standard.set(true, forKey: Keys.dailyGoalNotificationSent)

        let content = UNMutableNotificationContent()
        content.title = "🎉 Daily Goal Reached!"
        content.body = "You've completed \(formattedActiveTime) of work today. Great job!"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "dailyGoalReached", content: content, trigger: nil)

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("Failed to send notification: \(error)")
            }
        }
    }
}
