import Foundation
import IOKit.pwr_mgt
import Quartz

/// Detects system idle state via input events and power assertions
class IdleDetector {

    // MARK: - Singleton

    static let shared = IdleDetector()

    // MARK: - Constants

    private static let trackedEventTypes: [CGEventType] = [
        .mouseMoved,
        .keyDown,
        .leftMouseDown,
        .scrollWheel,
    ]

    private static let caffeinateAssertionName = "trakr Prevent Sleep" as CFString

    // MARK: - Properties

    private var caffeinateAssertionID: IOPMAssertionID = 0
    private(set) var isCaffeinateActive: Bool = false

    // MARK: - Initialization

    private init() {}

    // MARK: - Public Methods

    /// Returns the time in seconds since the last user input event
    func getSystemIdleTime() -> TimeInterval {
        Self.trackedEventTypes
            .map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }
            .min() ?? .infinity
    }

    /// Returns true if any app (other than our own caffeinate) is preventing display sleep
    func hasActivePowerAssertions() -> Bool {
        var assertionsStatus: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsStatus(&assertionsStatus) == kIOReturnSuccess,
            let dict = assertionsStatus?.takeRetainedValue() as? [String: Int]
        else {
            return false
        }

        // PreventUserIdleDisplaySleep is created by apps like Zoom, video players
        // (PreventUserIdleSystemSleep is always active from powerd when display is on, so we skip it)
        let displaySleepCount = dict["PreventUserIdleDisplaySleep"] ?? 0
        let noDisplaySleepCount = dict["NoDisplaySleepAssertion"] ?? 0

        // If our caffeinate is active, we contribute 1 to the PreventUserIdleDisplaySleep count
        // Only return true if there are OTHER assertions beyond our own
        let ourContribution = isCaffeinateActive ? 1 : 0
        let externalDisplaySleepCount = displaySleepCount - ourContribution

        return externalDisplaySleepCount > 0 || noDisplaySleepCount > 0
    }

    /// Returns true if the user is currently active (input or power assertion)
    func isUserActive(idleThreshold: TimeInterval) -> Bool {
        let isInputActive = getSystemIdleTime() < idleThreshold
        let hasPowerAssertion = hasActivePowerAssertions()
        return isInputActive || hasPowerAssertion
    }

    // MARK: - Caffeinate Control

    /// Starts preventing the computer from sleeping
    func startCaffeinate() {
        guard !isCaffeinateActive else { return }

        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            Self.caffeinateAssertionName,
            &caffeinateAssertionID
        )

        if result == kIOReturnSuccess {
            isCaffeinateActive = true
        }
    }

    /// Stops preventing the computer from sleeping
    func stopCaffeinate() {
        guard isCaffeinateActive else { return }

        IOPMAssertionRelease(caffeinateAssertionID)
        caffeinateAssertionID = 0
        isCaffeinateActive = false
    }
}
