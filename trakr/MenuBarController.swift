import AppKit
import Combine
import SwiftUI

class MenuBarController {

    // MARK: - Properties

    private var statusItem: NSStatusItem
    private var menu: NSMenu
    private var infoMenuItem: NSMenuItem
    private var pauseMenuItem: NSMenuItem
    private var settingsSubmenu: NSMenu
    private var cancellables = Set<AnyCancellable>()
    private var updateTimer: Timer?
    private var progressHostingView: NSHostingView<ProgressRingView>?

    private let presetDurations = [
        (title: "7.5 hours", seconds: 7 * 3600 + 30 * 60),
        (title: "8 hours", seconds: 8 * 3600),
        (title: "8.5 hours", seconds: 8 * 3600 + 30 * 60),
    ]

    private let presetIdleThresholds = [60, 120, 180, 300, 600]

    // MARK: - Initialization

    init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu = NSMenu()
        settingsSubmenu = NSMenu()
        infoMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        pauseMenuItem = NSMenuItem()

        setupStatusButton()
        setupMenu()
        setupObservers()
        SlackPresenceMonitor.shared.start()
    }

    deinit {
        updateTimer?.invalidate()
    }

    // MARK: - Setup

    private func setupStatusButton() {
        guard let button = statusItem.button else { return }
        button.image = NSImage(
            systemSymbolName: "cellularbars",
            variableValue: 0.0,
            accessibilityDescription: "Activity Timer"
        )
        button.image?.isTemplate = true
    }

    private func setupMenu() {
        infoMenuItem.view = createInfoView()
        menu.addItem(infoMenuItem)
        menu.addItem(.separator())

        pauseMenuItem = createMenuItem(
            title: "Pause Tracking", action: #selector(togglePause), keyEquivalent: "p")
        menu.addItem(pauseMenuItem)

        setupSettingsMenu()

        menu.addItem(.separator())
        menu.addItem(createMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    private func setupSettingsMenu() {
        let settingsMenuItem = NSMenuItem(title: "Settings", action: nil, keyEquivalent: ",")
        settingsMenuItem.submenu = settingsSubmenu

        // Idle Threshold submenu
        let idleSubmenu = createIdleThresholdSubmenu()
        let idleItem = NSMenuItem(title: "Idle Threshold", action: nil, keyEquivalent: "")
        idleItem.submenu = idleSubmenu
        settingsSubmenu.addItem(idleItem)

        // Target Work Day submenu
        let targetSubmenu = createTargetDurationSubmenu()
        let targetItem = NSMenuItem(title: "Target Work Day", action: nil, keyEquivalent: "")
        targetItem.submenu = targetSubmenu
        settingsSubmenu.addItem(targetItem)

        // Screen Overlay toggle
        settingsSubmenu.addItem(.separator())
        let overlayItem = createMenuItem(
            title: "Screen Overlay on Goal", action: #selector(toggleScreenOverlay))
        overlayItem.state = ActivityTracker.shared.screenOverlayEnabled ? .on : .off
        settingsSubmenu.addItem(overlayItem)

        // Zoom Standing Reminder toggle
        let zoomReminderItem = createMenuItem(
            title: "Zoom Standing Reminder", action: #selector(toggleZoomStandingReminder))
        zoomReminderItem.state = ActivityTracker.shared.zoomStandingReminderEnabled ? .on : .off
        settingsSubmenu.addItem(zoomReminderItem)

        // Slack settings
        settingsSubmenu.addItem(.separator())
        let slackEnabledItem = createMenuItem(
            title: "Slack Presence", action: #selector(toggleSlackEnabled))
        slackEnabledItem.state = SlackPresenceMonitor.shared.isEnabled ? .on : .off
        settingsSubmenu.addItem(slackEnabledItem)
        let slackRequireAppItem = createMenuItem(
            title: "Require Slack App Open", action: #selector(toggleSlackRequireApp))
        slackRequireAppItem.state = SlackPresenceMonitor.shared.requireSlackApp ? .on : .off
        settingsSubmenu.addItem(slackRequireAppItem)
        settingsSubmenu.addItem(
            createMenuItem(title: "Slack Credentials...", action: #selector(showSlackCredentialsInput)))
        settingsSubmenu.addItem(
            createMenuItem(title: "Slack User IDs...", action: #selector(showSlackCoworkersInput)))

        updateSettingsMenuStates()
        menu.addItem(settingsMenuItem)
    }

    private func createIdleThresholdSubmenu() -> NSMenu {
        let submenu = NSMenu()
        let currentValue = Int(ActivityTracker.shared.idleThreshold)

        for seconds in presetIdleThresholds {
            let title = formatIdleThreshold(seconds)
            let item = createMenuItem(title: title, action: #selector(setIdleThreshold(_:)))
            item.tag = seconds
            item.state = seconds == currentValue ? .on : .off
            submenu.addItem(item)
        }

        submenu.addItem(.separator())
        submenu.addItem(
            createMenuItem(title: "Custom...", action: #selector(showCustomIdleThresholdInput)))

        return submenu
    }

    private func createTargetDurationSubmenu() -> NSMenu {
        let submenu = NSMenu()
        let currentValue = ActivityTracker.shared.targetWorkDaySeconds

        for preset in presetDurations {
            let item = createMenuItem(
                title: preset.title, action: #selector(setTargetWorkDayDuration(_:)))
            item.tag = preset.seconds
            item.state = preset.seconds == currentValue ? .on : .off
            submenu.addItem(item)
        }

        submenu.addItem(.separator())
        submenu.addItem(
            createMenuItem(title: "Custom...", action: #selector(showCustomDurationInput)))

        return submenu
    }

    private func createMenuItem(title: String, action: Selector, keyEquivalent: String = "")
        -> NSMenuItem
    {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        return item
    }

    private func setupObservers() {
        updateTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateMenuItemTitle()
        }
        RunLoop.current.add(updateTimer!, forMode: .common)

        ActivityTracker.shared.$activeSeconds
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateMenuItemTitle() }
            .store(in: &cancellables)

        ActivityTracker.shared.$workStartTime
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateMenuItemTitle() }
            .store(in: &cancellables)

        ActivityTracker.shared.$isCurrentlyActive
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateStatusIcon() }
            .store(in: &cancellables)

        ActivityTracker.shared.$isPaused
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateStatusIcon()
                self?.updatePauseMenuItem()
            }
            .store(in: &cancellables)

        SlackPresenceMonitor.shared.$onlineInitials
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateStatusIcon() }
            .store(in: &cancellables)
    }

    // MARK: - UI Updates

    private func createProgressRingView() -> ProgressRingView {
        let tracker = ActivityTracker.shared
        let progress = Double(tracker.activeSeconds) / Double(tracker.targetWorkDaySeconds)

        return ProgressRingView(
            progress: progress,
            activeTime: tracker.formattedActiveTime,
            startTime: tracker.formattedWorkStartTime ?? "—",
            finishTime: tracker.formattedEstimatedFinishTime ?? "—",
            idleTime: tracker.formattedIdleTime ?? "—"
        )
    }

    private func createInfoView() -> NSView {
        let hostingView = NSHostingView(rootView: createProgressRingView())
        hostingView.frame = NSRect(x: 0, y: 0, width: 185, height: 96)
        progressHostingView = hostingView
        return hostingView
    }

    private func updateInfoView() {
        progressHostingView?.rootView = createProgressRingView()
    }

    private func updateMenuItemTitle() {
        updateInfoView()
        updateStatusIcon()
    }

    private func updateStatusIcon() {
        guard let button = statusItem.button else { return }

        let symbolName: String
        let variableValue: Double

        if ActivityTracker.shared.isPaused {
            symbolName = "pause.fill"
            variableValue = 0.0
        } else if ActivityTracker.shared.isCurrentlyActive {
            let progress = min(
                1.0,
                Double(ActivityTracker.shared.activeSeconds)
                    / Double(ActivityTracker.shared.targetWorkDaySeconds))
            symbolName = "cellularbars"
            variableValue = floor(progress * 4) / 4
        } else {
            symbolName = "hourglass"
            variableValue = 0.0
        }

        button.image = NSImage(
            systemSymbolName: symbolName,
            variableValue: variableValue,
            accessibilityDescription: "Activity Timer"
        )
        button.image?.isTemplate = true
        button.imagePosition = .imageRight

        // Display online coworker initials
        let initials = SlackPresenceMonitor.shared.onlineInitials
        button.title = initials.isEmpty ? "" : "\(initials) "
    }

    private func updatePauseMenuItem() {
        let isPaused = ActivityTracker.shared.isPaused
        pauseMenuItem.title = isPaused ? "Resume Tracking" : "Pause Tracking"
    }

    private func updateSettingsMenuStates() {
        if let idleSubmenu = settingsSubmenu.item(at: 0)?.submenu {
            let currentSeconds = Int(ActivityTracker.shared.idleThreshold)
            let presetValues = presetIdleThresholds
            updateSubmenuCheckmarks(
                submenu: idleSubmenu,
                currentValue: currentSeconds,
                presets: presetValues,
                formatTitle: formatIdleThreshold,
                action: #selector(setIdleThreshold(_:))
            )
        }

        if let targetSubmenu = settingsSubmenu.item(at: 1)?.submenu {
            let currentSeconds = ActivityTracker.shared.targetWorkDaySeconds
            let presetValues = presetDurations.map { $0.seconds }
            updateSubmenuCheckmarks(
                submenu: targetSubmenu,
                currentValue: currentSeconds,
                presets: presetValues,
                formatTitle: formatDuration,
                action: #selector(setTargetWorkDayDuration(_:))
            )
        }
    }

    private func updateSubmenuCheckmarks(
        submenu: NSMenu,
        currentValue: Int,
        presets: [Int],
        formatTitle: (Int) -> String,
        action: Selector
    ) {
        let isPreset = presets.contains(currentValue)

        // Remove existing custom value items
        let itemsToRemove = submenu.items
            .enumerated()
            .reversed()
            .filter { $0.element.tag == -1 && $0.element.action == action }
        for item in itemsToRemove {
            submenu.removeItem(at: item.offset)
        }

        // Update preset checkmarks
        for item in submenu.items where presets.contains(item.tag) {
            item.state = item.tag == currentValue ? .on : .off
        }

        // Add custom value if not a preset
        guard !isPreset else { return }

        let customItem = createMenuItem(title: formatTitle(currentValue), action: action)
        customItem.tag = -1
        customItem.state = .on
        customItem.representedObject = currentValue

        let insertIndex = findSortedInsertIndex(in: submenu, for: currentValue)
        submenu.insertItem(customItem, at: insertIndex)
    }

    private func findSortedInsertIndex(in submenu: NSMenu, for value: Int) -> Int {
        for (index, item) in submenu.items.enumerated() {
            if item.isSeparatorItem { return index }
            let itemValue = item.tag > 0 ? item.tag : 0
            if itemValue >= value { return index }
        }
        return 0
    }

    // MARK: - Formatting

    private func formatIdleThreshold(_ seconds: Int) -> String {
        if seconds < 60 {
            return "\(seconds)s"
        }
        let minutes = seconds / 60
        let remainder = seconds % 60
        return remainder > 0 ? "\(minutes)m \(remainder)s" : "\(minutes)m"
    }

    private func formatDuration(_ seconds: Int) -> String {
        let hours = Double(seconds) / 3600.0
        if hours.truncatingRemainder(dividingBy: 1) == 0 {
            return "\(Int(hours)) hours"
        }
        return String(format: "%.1f hours", hours)
    }

    // MARK: - Actions

    @objc private func quitApp() {
        ActivityTracker.shared.saveState()
        NSApplication.shared.terminate(nil)
    }

    @objc private func togglePause() {
        ActivityTracker.shared.togglePause()
    }

    @objc private func toggleScreenOverlay(_ sender: NSMenuItem) {
        ActivityTracker.shared.screenOverlayEnabled.toggle()
        sender.state = ActivityTracker.shared.screenOverlayEnabled ? .on : .off

        // If disabled, hide any current overlay
        if !ActivityTracker.shared.screenOverlayEnabled {
            ScreenOverlayController.shared.hideOverlayPermanently()
        }
    }

    @objc private func toggleZoomStandingReminder(_ sender: NSMenuItem) {
        ActivityTracker.shared.zoomStandingReminderEnabled.toggle()
        sender.state = ActivityTracker.shared.zoomStandingReminderEnabled ? .on : .off
    }

    @objc private func toggleSlackEnabled(_ sender: NSMenuItem) {
        SlackPresenceMonitor.shared.isEnabled.toggle()
        sender.state = SlackPresenceMonitor.shared.isEnabled ? .on : .off
    }

    @objc private func toggleSlackRequireApp(_ sender: NSMenuItem) {
        SlackPresenceMonitor.shared.requireSlackApp.toggle()
        sender.state = SlackPresenceMonitor.shared.requireSlackApp ? .on : .off
    }

    @objc private func setIdleThreshold(_ sender: NSMenuItem) {
        let seconds = sender.tag == -1 ? (sender.representedObject as? Int ?? 0) : sender.tag
        ActivityTracker.shared.idleThreshold = TimeInterval(seconds)
        updateSettingsMenuStates()
    }

    @objc private func setTargetWorkDayDuration(_ sender: NSMenuItem) {
        let seconds = sender.tag == -1 ? (sender.representedObject as? Int ?? 0) : sender.tag
        ActivityTracker.shared.targetWorkDaySeconds = seconds
        updateSettingsMenuStates()
        updateMenuItemTitle()
    }

    @objc private func showCustomDurationInput() {
        let currentHours = Double(ActivityTracker.shared.targetWorkDaySeconds) / 3600.0
        showCustomInput(
            title: "Set Target Work Day",
            message: "Enter duration in hours (e.g., 7.5):",
            currentValue: String(format: "%.1f", currentHours),
            validate: { Double($0).flatMap { $0 > 0 && $0 <= 24 ? Int($0 * 3600) : nil } },
            onConfirm: { [weak self] seconds in
                ActivityTracker.shared.targetWorkDaySeconds = seconds
                self?.updateSettingsMenuStates()
                self?.updateMenuItemTitle()
            }
        )
    }

    @objc private func showCustomIdleThresholdInput() {
        let currentSeconds = Int(ActivityTracker.shared.idleThreshold)
        showCustomInput(
            title: "Set Idle Threshold",
            message: "Enter threshold in seconds (e.g., 90):",
            currentValue: String(currentSeconds),
            validate: { Int($0).flatMap { $0 > 0 && $0 <= 3600 ? $0 : nil } },
            onConfirm: { [weak self] seconds in
                ActivityTracker.shared.idleThreshold = TimeInterval(seconds)
                self?.updateSettingsMenuStates()
            }
        )
    }

    private func showCustomInput(
        title: String,
        message: String,
        currentValue: String,
        validate: (String) -> Int?,
        onConfirm: @escaping (Int) -> Void
    ) {
        // Activate the app to ensure the alert gets focus (important for menu bar apps)
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        let inputField = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        inputField.stringValue = currentValue
        alert.accessoryView = inputField
        alert.window.initialFirstResponder = inputField

        guard alert.runModal() == .alertFirstButtonReturn,
            let value = validate(inputField.stringValue)
        else { return }

        onConfirm(value)
    }

    // MARK: - Slack Settings

    @objc private func showSlackCredentialsInput() {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "Slack Credentials"
        alert.informativeText = "Enter your Slack cookie and token:"
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        let containerView = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 70))

        let cookieLabel = NSTextField(labelWithString: "Cookie (d=):")
        cookieLabel.frame = NSRect(x: 0, y: 46, width: 80, height: 17)

        let cookieField = NSTextField(frame: NSRect(x: 85, y: 44, width: 215, height: 22))
        cookieField.stringValue = SlackPresenceMonitor.shared.cookie
        cookieField.placeholderString = "xoxd-..."

        let tokenLabel = NSTextField(labelWithString: "Token:")
        tokenLabel.frame = NSRect(x: 0, y: 14, width: 80, height: 17)

        let tokenField = NSTextField(frame: NSRect(x: 85, y: 12, width: 215, height: 22))
        tokenField.stringValue = SlackPresenceMonitor.shared.token
        tokenField.placeholderString = "xoxc-..."

        containerView.addSubview(cookieLabel)
        containerView.addSubview(cookieField)
        containerView.addSubview(tokenLabel)
        containerView.addSubview(tokenField)

        alert.accessoryView = containerView
        alert.window.initialFirstResponder = cookieField

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let cookie = cookieField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = tokenField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cookie.isEmpty, !token.isEmpty else { return }

        SlackPresenceMonitor.shared.cookie = cookie
        SlackPresenceMonitor.shared.token = token
        SlackPresenceMonitor.shared.reconnect()
    }

    @objc private func showSlackCoworkersInput() {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "Slack User IDs"
        alert.informativeText = "Enter one coworker per line (format: ID:Name):\ne.g., U01ABC:Alice"
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 350, height: 120))
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 350, height: 120))
        textView.isEditable = true
        textView.isSelectable = true
        textView.font = NSFont.systemFont(ofSize: 13)
        textView.string = formatCoworkersForDisplay(multiline: true)
        textView.autoresizingMask = [.width]

        scrollView.documentView = textView

        alert.accessoryView = scrollView
        alert.window.initialFirstResponder = textView

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let input = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }

        var coworkers: [String: String] = [:]
        // Support both newlines and commas as separators
        let normalized = input.replacingOccurrences(of: "\n", with: ",")
        let entries = normalized.split(separator: ",")
        for entry in entries {
            let parts = entry.split(separator: ":", maxSplits: 1)
            if parts.count == 2 {
                let userId = String(parts[0]).trimmingCharacters(in: .whitespaces)
                let name = String(parts[1]).trimmingCharacters(in: .whitespaces)
                if !userId.isEmpty, !name.isEmpty {
                    coworkers[userId] = name
                }
            }
        }

        guard !coworkers.isEmpty else { return }

        SlackPresenceMonitor.shared.coworkers = coworkers
        SlackPresenceMonitor.shared.reconnect()
    }

    private func formatCoworkersForDisplay(multiline: Bool = false) -> String {
        SlackPresenceMonitor.shared.coworkers
            .map { "\($0.key):\($0.value)" }
            .joined(separator: multiline ? "\n" : ",")
    }
}
