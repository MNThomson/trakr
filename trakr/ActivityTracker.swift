import Foundation
import Quartz

class ActivityTracker: ObservableObject {

    // MARK: - Constants

    private enum Keys {
        static let activeSeconds = "activeSeconds"
        static let lastActiveDate = "lastActiveDate"
        static let workStartTime = "workStartTime"
        static let idleThreshold = "idleThreshold"
        static let targetWorkDaySeconds = "targetWorkDaySeconds"
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
        .scrollWheel
    ]

    // MARK: - Singleton

    static let shared = ActivityTracker()

    // MARK: - Published Properties

    @Published private(set) var activeSeconds: Int = 0
    @Published private(set) var workStartTime: Date?
    @Published private(set) var isCurrentlyActive: Bool = false
    @Published var targetWorkDaySeconds: Int {
        didSet { UserDefaults.standard.set(targetWorkDaySeconds, forKey: Keys.targetWorkDaySeconds) }
    }

    // MARK: - Properties

    var idleThreshold: TimeInterval {
        didSet { UserDefaults.standard.set(idleThreshold, forKey: Keys.idleThreshold) }
    }

    private var timer: Timer?

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
        targetWorkDaySeconds = savedTargetSeconds > 0 ? savedTargetSeconds : Defaults.targetWorkDaySeconds

        loadState()
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
        guard let lastDate = UserDefaults.standard.object(forKey: Keys.lastActiveDate) as? Date else {
            resetToInitialState()
            return
        }

        if isSameWorkDay(lastDate, as: Date()) {
            activeSeconds = UserDefaults.standard.integer(forKey: Keys.activeSeconds)
            workStartTime = UserDefaults.standard.object(forKey: Keys.workStartTime) as? Date
        } else {
            resetForNewWorkDay()
        }
    }

    private func resetToInitialState() {
        activeSeconds = 0
        workStartTime = nil
    }

    private func resetForNewWorkDay() {
        resetToInitialState()
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
           !isSameWorkDay(lastDate, as: now) {
            resetForNewWorkDay()
        }

        isCurrentlyActive = getSystemIdleTime() < idleThreshold
        guard isCurrentlyActive else { return }

        if workStartTime == nil && isAfterWorkDayStart(now) {
            workStartTime = now
            saveState()
        }

        activeSeconds += 1

        if activeSeconds % Defaults.saveInterval == 0 {
            saveState()
        }
    }

    private func getSystemIdleTime() -> TimeInterval {
        Self.trackedEventTypes
            .map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }
            .min() ?? .infinity
    }

    // MARK: - Work Day Logic

    private func isSameWorkDay(_ date1: Date, as date2: Date) -> Bool {
        let calendar = Calendar.current
        let adjusted1 = calendar.date(byAdding: .hour, value: -Defaults.workDayStartHour, to: date1)!
        let adjusted2 = calendar.date(byAdding: .hour, value: -Defaults.workDayStartHour, to: date2)!
        return calendar.isDate(adjusted1, inSameDayAs: adjusted2)
    }

    private func isAfterWorkDayStart(_ date: Date) -> Bool {
        Calendar.current.component(.hour, from: date) >= Defaults.workDayStartHour
    }
}
