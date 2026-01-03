import Foundation
import Quartz

class ActivityTracker: ObservableObject {

    // MARK: - Constants

    private enum Defaults {
        static let idleThreshold: TimeInterval = 120
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
    @Published private(set) var isCurrentlyActive: Bool = false

    // MARK: - Properties

    var idleThreshold: TimeInterval = Defaults.idleThreshold

    private var timer: Timer?

    // MARK: - Computed Properties

    var formattedActiveTime: String {
        let hours = activeSeconds / 3600
        let minutes = (activeSeconds % 3600) / 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }

    // MARK: - Initialization

    private init() {
        startTracking()
    }

    deinit {
        timer?.invalidate()
    }

    // MARK: - Activity Tracking

    private func startTracking() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.checkActivity()
        }
        RunLoop.current.add(timer!, forMode: .common)
    }

    private func checkActivity() {
        isCurrentlyActive = getSystemIdleTime() < idleThreshold
        guard isCurrentlyActive else { return }
        activeSeconds += 1
    }

    private func getSystemIdleTime() -> TimeInterval {
        Self.trackedEventTypes
            .map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }
            .min() ?? .infinity
    }
}
