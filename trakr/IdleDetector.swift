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

    // MARK: - Initialization

    private init() {}

    // MARK: - Public Methods

    /// Returns the time in seconds since the last user input event
    func getSystemIdleTime() -> TimeInterval {
        Self.trackedEventTypes
            .map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }
            .min() ?? .infinity
    }

    /// Returns true if any app is preventing display sleep (e.g., Zoom, video players)
    func hasActivePowerAssertions() -> Bool {
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

    /// Returns true if the user is currently active (input or power assertion)
    func isUserActive(idleThreshold: TimeInterval) -> Bool {
        let isInputActive = getSystemIdleTime() < idleThreshold
        let hasPowerAssertion = hasActivePowerAssertions()
        return isInputActive || hasPowerAssertion
    }
}
