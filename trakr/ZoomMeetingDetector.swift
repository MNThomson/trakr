import AppKit
import Foundation

/// Detects Zoom meeting state by checking for the CptHost helper process
class ZoomMeetingDetector {

    // MARK: - Singleton

    static let shared = ZoomMeetingDetector()

    // MARK: - Properties

    private(set) var isInMeeting: Bool = false

    /// Called when user joins a meeting (after verification delay)
    var onMeetingJoined: (() -> Void)?

    // MARK: - Constants

    /// Delay before confirming meeting join to avoid false positives
    private let verificationDelay: TimeInterval = 10

    // MARK: - Initialization

    private init() {}

    // MARK: - Public Methods

    /// Check for Zoom meeting state changes and trigger callback on join
    func checkStateChange() {
        let inMeetingNow = checkForZoomMeeting()

        // Trigger callback on transition: not in meeting -> in meeting
        if inMeetingNow && !isInMeeting {
            // Delay notification, verify still in meeting before triggering
            DispatchQueue.main.asyncAfter(deadline: .now() + verificationDelay) { [weak self] in
                guard let self = self, self.checkForZoomMeeting() else { return }
                self.onMeetingJoined?()
            }
        }

        isInMeeting = inMeetingNow
    }

    // MARK: - Private Methods

    /// Returns true if currently in a Zoom meeting
    private func checkForZoomMeeting() -> Bool {
        // CptHost is a Zoom helper process that runs when you're in a meeting
        let runningApps = NSWorkspace.shared.runningApplications
        return runningApps.contains { app in
            guard let bundleId = app.bundleIdentifier else { return false }
            // CptHost.app is spawned when joining a Zoom meeting
            return bundleId == "us.zoom.CptHost"
        }
    }
}

