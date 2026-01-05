import Foundation

class ActivityTracker: ObservableObject {

    // MARK: - Constants

    private enum Keys {
        static let activeSeconds = "activeSeconds"
        static let lastActiveDate = "lastActiveDate"
        static let workStartTime = "workStartTime"
        static let idleThreshold = "idleThreshold"
        static let targetWorkDaySeconds = "targetWorkDaySeconds"
        static let goalReachedTime = "goalReachedTime"
        static let screenOverlayEnabled = "screenOverlayEnabled"
        static let zoomStandingReminderEnabled = "zoomStandingReminderEnabled"
        static let eyeBreakIntervalMinutes = "eyeBreakIntervalMinutes"
        static let stretchBreakEnabled = "stretchBreakEnabled"
        static let postZoomStretchEnabled = "postZoomStretchEnabled"
        static let windDownMinutes = "windDownMinutes"
        static let sunsetAlertMinutes = "sunsetAlertMinutes"
    }

    private enum Defaults {
        static let idleThreshold: TimeInterval = 120
        static let targetWorkDaySeconds = 8 * 3600
        static let workDayStartHour = 4
        static let saveInterval = 30
    }

    // MARK: - Singleton

    static let shared = ActivityTracker()

    // MARK: - Published Properties

    @Published private(set) var activeSeconds: Int = 0
    @Published private(set) var workStartTime: Date?
    @Published private(set) var isCurrentlyActive: Bool = false
    @Published private(set) var isPaused: Bool = false
    @Published var targetWorkDaySeconds: Int {
        didSet {
            UserDefaults.standard.set(targetWorkDaySeconds, forKey: Keys.targetWorkDaySeconds)
            // Clear goal if new target exceeds current active time
            if activeSeconds < targetWorkDaySeconds {
                goalReachedTime = nil
                UserDefaults.standard.removeObject(forKey: Keys.goalReachedTime)
            }
        }
    }

    // MARK: - Properties

    var idleThreshold: TimeInterval {
        didSet { UserDefaults.standard.set(idleThreshold, forKey: Keys.idleThreshold) }
    }

    var screenOverlayEnabled: Bool {
        didSet {
            UserDefaults.standard.set(screenOverlayEnabled, forKey: Keys.screenOverlayEnabled)
        }
    }

    var zoomStandingReminderEnabled: Bool {
        didSet {
            UserDefaults.standard.set(
                zoomStandingReminderEnabled, forKey: Keys.zoomStandingReminderEnabled)
        }
    }

    var eyeBreakIntervalMinutes: Int {
        didSet {
            UserDefaults.standard.set(eyeBreakIntervalMinutes, forKey: Keys.eyeBreakIntervalMinutes)
        }
    }

    var stretchBreakEnabled: Bool {
        didSet { UserDefaults.standard.set(stretchBreakEnabled, forKey: Keys.stretchBreakEnabled) }
    }

    var postZoomStretchEnabled: Bool {
        didSet {
            UserDefaults.standard.set(postZoomStretchEnabled, forKey: Keys.postZoomStretchEnabled)
        }
    }

    var windDownMinutes: Int {
        didSet { UserDefaults.standard.set(windDownMinutes, forKey: Keys.windDownMinutes) }
    }

    var sunsetAlertMinutes: Int {
        didSet { UserDefaults.standard.set(sunsetAlertMinutes, forKey: Keys.sunsetAlertMinutes) }
    }

    private var timer: Timer?
    private var goalReachedTime: Date?
    private var secondsSinceLastEyeBreak: Int = 0
    private var lastStretchBreakHour: Int?
    private var windDownShown: Bool = false
    private var sunsetAlertShown: Bool = false

    private lazy var timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter
    }()

    // MARK: - Computed Properties

    var formattedActiveTime: String {
        let hours = activeSeconds / 3600
        let minutes = (activeSeconds % 3600) / 60
        return hours > 0 ? "\(hours)h\(minutes)m" : "\(minutes)m"
    }

    var formattedWorkStartTime: String? {
        workStartTime.map { timeFormatter.string(from: $0) }
    }

    var formattedEstimatedFinishTime: String? {
        guard workStartTime != nil else { return nil }
        if let goalTime = goalReachedTime {
            return timeFormatter.string(from: goalTime)
        }
        let remainingSeconds = targetWorkDaySeconds - activeSeconds
        let estimatedFinish = Date().addingTimeInterval(TimeInterval(remainingSeconds))
        return timeFormatter.string(from: estimatedFinish)
    }

    var formattedIdleTime: String? {
        guard let start = workStartTime else { return nil }

        // After goal is reached, show break time it took to reach the goal (frozen)
        // Before goal, show current accumulated break time
        let endTime: Date
        let activeSecondsToUse: Int

        if let goalTime = goalReachedTime {
            endTime = goalTime
            activeSecondsToUse = targetWorkDaySeconds
        } else {
            endTime = Date()
            activeSecondsToUse = activeSeconds
        }

        let elapsedSeconds = Int(endTime.timeIntervalSince(start))
        let idleSeconds = max(0, elapsedSeconds - activeSecondsToUse)
        let hours = idleSeconds / 3600
        let minutes = (idleSeconds % 3600) / 60
        return hours > 0 ? "\(hours)h\(minutes)m" : "\(minutes)m"
    }

    // MARK: - Initialization

    private init() {
        let savedIdleThreshold = UserDefaults.standard.double(forKey: Keys.idleThreshold)
        idleThreshold = savedIdleThreshold > 0 ? savedIdleThreshold : Defaults.idleThreshold

        let savedTargetSeconds = UserDefaults.standard.integer(forKey: Keys.targetWorkDaySeconds)
        targetWorkDaySeconds =
            savedTargetSeconds > 0 ? savedTargetSeconds : Defaults.targetWorkDaySeconds

        // Default to disabled if not set
        screenOverlayEnabled = UserDefaults.standard.bool(forKey: Keys.screenOverlayEnabled)

        // Default Zoom standing reminder to disabled if not set
        zoomStandingReminderEnabled = UserDefaults.standard.bool(
            forKey: Keys.zoomStandingReminderEnabled)

        // Break reminder settings (0 = disabled)
        eyeBreakIntervalMinutes = UserDefaults.standard.integer(
            forKey: Keys.eyeBreakIntervalMinutes)
        stretchBreakEnabled = UserDefaults.standard.bool(forKey: Keys.stretchBreakEnabled)
        postZoomStretchEnabled = UserDefaults.standard.bool(forKey: Keys.postZoomStretchEnabled)
        windDownMinutes = UserDefaults.standard.integer(forKey: Keys.windDownMinutes)

        // Sunset alert settings (0 = disabled)
        sunsetAlertMinutes = UserDefaults.standard.integer(forKey: Keys.sunsetAlertMinutes)

        loadState()
        setupZoomDetector()
        NotificationService.shared.requestPermissions()
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

    func togglePause() {
        isPaused.toggle()
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
            goalReachedTime = UserDefaults.standard.object(forKey: Keys.goalReachedTime) as? Date
        } else {
            resetForNewWorkDay()
        }
    }

    private func resetToInitialState() {
        activeSeconds = 0
        workStartTime = nil
        goalReachedTime = nil
    }

    private func resetForNewWorkDay() {
        resetToInitialState()
        windDownShown = false
        sunsetAlertShown = false
        UserDefaults.standard.removeObject(forKey: Keys.goalReachedTime)
        saveState()
    }

    // MARK: - Zoom Meeting Detection

    private func setupZoomDetector() {
        ZoomMeetingDetector.shared.onMeetingJoined = { [weak self] in
            guard let self = self, self.zoomStandingReminderEnabled else { return }
            EmojiFlashController.shared.flash(emoji: "🧍")
        }

        ZoomMeetingDetector.shared.onMeetingLeft = { [weak self] in
            guard let self = self, self.postZoomStretchEnabled else { return }
            EmojiFlashController.shared.flash(emoji: "🚶")
        }
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

        // Check for Zoom meeting state changes (for standing reminder and post-zoom stretch)
        if zoomStandingReminderEnabled || postZoomStretchEnabled {
            ZoomMeetingDetector.shared.checkStateChange()
        }

        // Check for hourly stretch break at minute 55 (clock-based, skip if in Zoom)
        checkStretchBreak(now: now)

        // Check for sunset alert (clock-based)
        checkSunsetAlert()

        isCurrentlyActive = IdleDetector.shared.isUserActive(idleThreshold: idleThreshold)
        guard isCurrentlyActive && !isPaused else { return }

        if workStartTime == nil && isAfterWorkDayStart(now) {
            workStartTime = now
            saveState()
        }

        activeSeconds += 1

        // Check for eye break (active time based)
        checkEyeBreak()

        // Check for wind-down reminder (20 minutes before goal)
        checkWindDown()

        if activeSeconds >= targetWorkDaySeconds && goalReachedTime == nil {
            goalReachedTime = now
            UserDefaults.standard.set(now, forKey: Keys.goalReachedTime)
            NotificationService.shared.sendDailyGoalNotification(
                formattedActiveTime: formattedActiveTime)
            if screenOverlayEnabled {
                ScreenOverlayController.shared.showOverlay()
            }
        }

        if activeSeconds % Defaults.saveInterval == 0 {
            saveState()
        }
    }

    // MARK: - Break Reminders

    private func checkEyeBreak() {
        guard eyeBreakIntervalMinutes > 0 else {
            secondsSinceLastEyeBreak = 0
            return
        }

        secondsSinceLastEyeBreak += 1
        let intervalSeconds = eyeBreakIntervalMinutes * 60

        if secondsSinceLastEyeBreak >= intervalSeconds {
            EmojiFlashController.shared.flash(emoji: "👀")
            secondsSinceLastEyeBreak = 0
        }
    }

    private func checkStretchBreak(now: Date) {
        guard stretchBreakEnabled else {
            lastStretchBreakHour = nil
            return
        }

        let calendar = Calendar.current
        let minute = calendar.component(.minute, from: now)
        let hour = calendar.component(.hour, from: now)

        // Trigger at minute 55, if not already triggered this hour and not in a Zoom meeting
        if minute == 55 && lastStretchBreakHour != hour && !ZoomMeetingDetector.shared.isInMeeting {
            EmojiFlashController.shared.flash(emoji: "🤸")
            lastStretchBreakHour = hour
        }
    }

    private func checkWindDown() {
        guard windDownMinutes > 0 && !windDownShown else { return }

        let remainingSeconds = targetWorkDaySeconds - activeSeconds
        let windDownSeconds = windDownMinutes * 60

        if remainingSeconds <= windDownSeconds && remainingSeconds > 0 {
            windDownShown = true
            EmojiFlashController.shared.flash(emoji: "⏱️")
        }
    }

    private func checkSunsetAlert() {
        guard sunsetAlertMinutes > 0 && !sunsetAlertShown else { return }
        guard SunsetCalculator.shared.hasLocation else { return }

        if let minutesUntil = SunsetCalculator.shared.minutesUntilSunset(),
            minutesUntil <= sunsetAlertMinutes && minutesUntil > 0
        {
            sunsetAlertShown = true
            EmojiFlashController.shared.flash(emoji: "🌅")
        }
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
}
