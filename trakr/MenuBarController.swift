import AppKit
import Combine
import SwiftUI

class MenuBarController {

    // MARK: - Properties

    private var statusItem: NSStatusItem
    private var menu: NSMenu
    private var infoMenuItem: NSMenuItem
    private var pauseMenuItem: NSMenuItem
    private var preventSleepMenuItem: NSMenuItem
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
    private let presetEyeBreakIntervals = [15, 20, 30]  // minutes
    private let presetWindDownMinutes = [15, 20, 30, 45]  // minutes
    private let presetSunsetAlertMinutes = [15, 30, 45, 60]  // minutes

    // MARK: - Initialization

    init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu = NSMenu()
        settingsSubmenu = NSMenu()
        infoMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        pauseMenuItem = NSMenuItem()
        preventSleepMenuItem = NSMenuItem()

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

        preventSleepMenuItem = createMenuItem(
            title: "Prevent Sleep", action: #selector(togglePreventSleep), keyEquivalent: "s")
        menu.addItem(preventSleepMenuItem)

        setupSettingsMenu()

        menu.addItem(.separator())
        menu.addItem(createMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    private func setupSettingsMenu() {
        let settingsMenuItem = NSMenuItem(title: "Settings", action: nil, keyEquivalent: ",")
        settingsMenuItem.submenu = settingsSubmenu

        // MARK: Core Settings
        let idleSubmenu = createIdleThresholdSubmenu()
        let idleItem = NSMenuItem(title: "Idle Threshold", action: nil, keyEquivalent: "")
        idleItem.submenu = idleSubmenu
        settingsSubmenu.addItem(idleItem)

        let targetSubmenu = createTargetDurationSubmenu()
        let targetItem = NSMenuItem(title: "Daily Hours Goal", action: nil, keyEquivalent: "")
        targetItem.submenu = targetSubmenu
        settingsSubmenu.addItem(targetItem)

        settingsSubmenu.addItem(.separator())

        // MARK: Goal, Breaks, Zoom, Time/Environment
        setupRemindersMenu()

        // MARK: Integrations
        settingsSubmenu.addItem(.separator())
        let slackSubmenu = createSlackSubmenu()
        let slackItem = NSMenuItem(title: "Slack Presence", action: nil, keyEquivalent: "")
        slackItem.submenu = slackSubmenu
        slackItem.state = SlackPresenceMonitor.shared.isEnabled ? .on : .off
        settingsSubmenu.addItem(slackItem)

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

    private func setupRemindersMenu() {
        // Goal
        let overlayItem = createMenuItem(
            title: "Screen Overlay on Goal", action: #selector(toggleScreenOverlay))
        overlayItem.state = ActivityTracker.shared.screenOverlayEnabled ? .on : .off
        settingsSubmenu.addItem(overlayItem)

        let windDownTimingSubmenu = createWindDownTimingSubmenu()
        let windDownTimingItem = NSMenuItem(
            title: "Wrap-Up Reminder", action: nil, keyEquivalent: "")
        windDownTimingItem.submenu = windDownTimingSubmenu
        windDownTimingItem.state = ActivityTracker.shared.windDownMinutes > 0 ? .on : .off
        settingsSubmenu.addItem(windDownTimingItem)

        // Breaks
        let eyeBreakIntervalSubmenu = createEyeBreakIntervalSubmenu()
        let eyeBreakIntervalItem = NSMenuItem(
            title: "Eye Break (20-20-20)", action: nil, keyEquivalent: "")
        eyeBreakIntervalItem.submenu = eyeBreakIntervalSubmenu
        eyeBreakIntervalItem.state = ActivityTracker.shared.eyeBreakIntervalMinutes > 0 ? .on : .off
        settingsSubmenu.addItem(eyeBreakIntervalItem)

        let stretchBreakItem = createMenuItem(
            title: "Stretch Break (Hourly)", action: #selector(toggleStretchBreak))
        stretchBreakItem.state = ActivityTracker.shared.stretchBreakEnabled ? .on : .off
        settingsSubmenu.addItem(stretchBreakItem)

        // Zoom
        let zoomReminderItem = createMenuItem(
            title: "Stand Up for Zoom", action: #selector(toggleZoomStandingReminder))
        zoomReminderItem.state = ActivityTracker.shared.zoomStandingReminderEnabled ? .on : .off
        settingsSubmenu.addItem(zoomReminderItem)

        let postZoomStretchItem = createMenuItem(
            title: "Stretch After Zoom", action: #selector(togglePostZoomStretch))
        postZoomStretchItem.state = ActivityTracker.shared.postZoomStretchEnabled ? .on : .off
        settingsSubmenu.addItem(postZoomStretchItem)

        // Time/Environment
        let sunsetAlertTimingSubmenu = createSunsetAlertTimingSubmenu()
        let sunsetAlertTimingItem = NSMenuItem(
            title: "Sunset Alert", action: nil, keyEquivalent: "")
        sunsetAlertTimingItem.submenu = sunsetAlertTimingSubmenu
        sunsetAlertTimingItem.state = ActivityTracker.shared.sunsetAlertMinutes > 0 ? .on : .off
        settingsSubmenu.addItem(sunsetAlertTimingItem)

        settingsSubmenu.addItem(
            createMenuItem(title: "Set Location...", action: #selector(showLocationInput)))
    }

    private func createEyeBreakIntervalSubmenu() -> NSMenu {
        let submenu = NSMenu()
        let currentValue = ActivityTracker.shared.eyeBreakIntervalMinutes

        // Disabled option (value = 0)
        let disabledItem = createMenuItem(
            title: "Disabled", action: #selector(setEyeBreakInterval(_:)))
        disabledItem.tag = 0
        disabledItem.state = currentValue == 0 ? .on : .off
        submenu.addItem(disabledItem)

        submenu.addItem(.separator())

        for minutes in presetEyeBreakIntervals {
            let title = "\(minutes) min"
            let item = createMenuItem(title: title, action: #selector(setEyeBreakInterval(_:)))
            item.tag = minutes
            item.state = minutes == currentValue ? .on : .off
            submenu.addItem(item)
        }

        submenu.addItem(.separator())
        submenu.addItem(
            createMenuItem(title: "Custom...", action: #selector(showCustomEyeBreakIntervalInput)))

        return submenu
    }

    private func createWindDownTimingSubmenu() -> NSMenu {
        let submenu = NSMenu()
        let currentValue = ActivityTracker.shared.windDownMinutes

        // Disabled option (value = 0)
        let disabledItem = createMenuItem(
            title: "Disabled", action: #selector(setWindDownTiming(_:)))
        disabledItem.tag = 0
        disabledItem.state = currentValue == 0 ? .on : .off
        submenu.addItem(disabledItem)

        submenu.addItem(.separator())

        for minutes in presetWindDownMinutes {
            let title = "\(minutes) min before"
            let item = createMenuItem(title: title, action: #selector(setWindDownTiming(_:)))
            item.tag = minutes
            item.state = minutes == currentValue ? .on : .off
            submenu.addItem(item)
        }

        submenu.addItem(.separator())
        submenu.addItem(
            createMenuItem(title: "Custom...", action: #selector(showCustomWindDownTimingInput)))

        return submenu
    }

    private func createSunsetAlertTimingSubmenu() -> NSMenu {
        let submenu = NSMenu()
        let currentValue = ActivityTracker.shared.sunsetAlertMinutes

        // Disabled option (value = 0)
        let disabledItem = createMenuItem(
            title: "Disabled", action: #selector(setSunsetAlertTiming(_:)))
        disabledItem.tag = 0
        disabledItem.state = currentValue == 0 ? .on : .off
        submenu.addItem(disabledItem)

        submenu.addItem(.separator())

        for minutes in presetSunsetAlertMinutes {
            let title = "\(minutes) min before"
            let item = createMenuItem(title: title, action: #selector(setSunsetAlertTiming(_:)))
            item.tag = minutes
            item.state = minutes == currentValue ? .on : .off
            submenu.addItem(item)
        }

        submenu.addItem(.separator())
        submenu.addItem(
            createMenuItem(title: "Custom...", action: #selector(showCustomSunsetAlertTimingInput)))

        return submenu
    }

    private func createSlackSubmenu() -> NSMenu {
        let submenu = NSMenu()

        let enabledItem = createMenuItem(title: "Enabled", action: #selector(toggleSlackEnabled))
        enabledItem.state = SlackPresenceMonitor.shared.isEnabled ? .on : .off
        submenu.addItem(enabledItem)

        let requireAppItem = createMenuItem(
            title: "Require App Open", action: #selector(toggleSlackRequireApp))
        requireAppItem.state = SlackPresenceMonitor.shared.requireSlackApp ? .on : .off
        submenu.addItem(requireAppItem)

        let meetingStatusItem = createMenuItem(
            title: "Show Meeting Status", action: #selector(toggleShowMeetingStatus))
        meetingStatusItem.state = SlackPresenceMonitor.shared.showMeetingStatus ? .on : .off
        submenu.addItem(meetingStatusItem)

        submenu.addItem(.separator())

        submenu.addItem(
            createMenuItem(title: "Credentials...", action: #selector(showSlackCredentialsInput)))
        submenu.addItem(
            createMenuItem(title: "User IDs...", action: #selector(showSlackCoworkersInput)))

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

        SlackPresenceMonitor.shared.$initialsInMeeting
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateStatusIcon() }
            .store(in: &cancellables)

        SlackPresenceMonitor.shared.$initialsUnavailable
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateStatusIcon() }
            .store(in: &cancellables)

        SlackPresenceMonitor.shared.$isMeActive
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateStatusIcon() }
            .store(in: &cancellables)

        SlackPresenceMonitor.shared.$onlineUserPhotos
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateStatusIcon() }
            .store(in: &cancellables)

        // Observe system appearance changes for icon tinting
        DistributedNotificationCenter.default()
            .publisher(for: Notification.Name("AppleInterfaceThemeChangedNotification"))
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

        guard
            let baseImage = NSImage(
                systemSymbolName: symbolName,
                variableValue: variableValue,
                accessibilityDescription: "Activity Timer"
            )
        else { return }

        let isMeActive = SlackPresenceMonitor.shared.isMeActive

        // Create composite image with activity indicator if "Me" is active
        if isMeActive {
            let compositeImage = createImageWithActivityDot(baseImage: baseImage)
            button.image = compositeImage
        } else {
            baseImage.isTemplate = true
            button.image = baseImage
        }

        button.imagePosition = .imageRight

        // Display online coworker profile photos
        let userPhotos = SlackPresenceMonitor.shared.onlineUserPhotos
        if userPhotos.isEmpty {
            button.attributedTitle = NSAttributedString(string: "")
        } else {
            // Create composite image with profile photos
            let photoImage = createProfilePhotosImage(users: userPhotos)
            if let photoImage = photoImage {
                // Use an attachment to display the image in the title
                let attachment = NSTextAttachment()
                attachment.image = photoImage
                // Adjust vertical alignment to center with the status icon
                let yOffset = (NSFont.menuBarFont(ofSize: 0).capHeight - photoImage.size.height) / 2
                attachment.bounds = CGRect(
                    x: 0, y: yOffset,
                    width: photoImage.size.width, height: photoImage.size.height)
                let imageString = NSMutableAttributedString(attachment: attachment)
                imageString.append(NSAttributedString(string: " "))
                button.attributedTitle = imageString
            } else {
                // Fallback to initials if no photos available
                displayInitialsFallback(button: button, users: userPhotos)
            }
        }
    }

    private func createProfilePhotosImage(users: [SlackPresenceMonitor.UserPhotoInfo]) -> NSImage? {
        let photoSize: CGFloat = 16  // Size for each profile photo
        let spacing: CGFloat = 2  // Spacing between photos
        let cornerRadius: CGFloat = 4  // Subtle rounding like Slack icons
        let borderWidth: CGFloat = 1.5

        // Filter users that have photos
        let usersWithPhotos = users.filter { $0.image != nil }
        let usersWithoutPhotos = users.filter { $0.image == nil }

        guard !usersWithPhotos.isEmpty || !usersWithoutPhotos.isEmpty else { return nil }

        let totalWidth =
            CGFloat(usersWithPhotos.count) * (photoSize + spacing)
            + CGFloat(usersWithoutPhotos.count) * (photoSize + spacing)
        let compositeImage = NSImage(size: NSSize(width: totalWidth, height: photoSize))

        compositeImage.lockFocus()

        var xOffset: CGFloat = 0

        // Draw users with photos first
        for user in usersWithPhotos {
            guard let photo = user.image else { continue }
            drawRoundedPhoto(
                photo: photo,
                at: NSPoint(x: xOffset, y: 0),
                size: photoSize,
                cornerRadius: cornerRadius,
                borderWidth: borderWidth,
                isInMeeting: user.isInMeeting,
                isUnavailable: user.isUnavailable
            )
            xOffset += photoSize + spacing
        }

        // Draw initials for users without photos
        for user in usersWithoutPhotos {
            drawInitialSquare(
                name: user.name,
                at: NSPoint(x: xOffset, y: 0),
                size: photoSize,
                cornerRadius: cornerRadius,
                borderWidth: borderWidth,
                isInMeeting: user.isInMeeting,
                isUnavailable: user.isUnavailable
            )
            xOffset += photoSize + spacing
        }

        compositeImage.unlockFocus()
        return compositeImage
    }

    private func drawRoundedPhoto(
        photo: NSImage,
        at point: NSPoint,
        size: CGFloat,
        cornerRadius: CGFloat,
        borderWidth: CGFloat,
        isInMeeting: Bool,
        isUnavailable: Bool
    ) {
        let rect = NSRect(x: point.x, y: point.y, width: size, height: size)

        // Create rounded rect clipping path
        let roundedPath = NSBezierPath(
            roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)

        // Draw border for status indication
        if isInMeeting {
            NSColor.systemOrange.setStroke()
            roundedPath.lineWidth = borderWidth
            roundedPath.stroke()
        } else if isUnavailable {
            NSColor.systemGray.setStroke()
            roundedPath.lineWidth = borderWidth
            roundedPath.stroke()
        }

        // Clip to rounded rect and draw photo
        NSGraphicsContext.saveGraphicsState()
        let insetRect = rect.insetBy(dx: borderWidth / 2, dy: borderWidth / 2)
        let insetPath = NSBezierPath(
            roundedRect: insetRect, xRadius: cornerRadius - borderWidth / 2,
            yRadius: cornerRadius - borderWidth / 2)
        insetPath.addClip()

        photo.draw(
            in: insetRect,
            from: NSRect(origin: .zero, size: photo.size),
            operation: .sourceOver,
            fraction: isUnavailable ? 0.5 : 1.0
        )
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawInitialSquare(
        name: String,
        at point: NSPoint,
        size: CGFloat,
        cornerRadius: CGFloat,
        borderWidth: CGFloat,
        isInMeeting: Bool,
        isUnavailable: Bool
    ) {
        let rect = NSRect(x: point.x, y: point.y, width: size, height: size)
        let roundedPath = NSBezierPath(
            roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)

        // Background color
        let isDarkMode = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let bgColor = isDarkMode ? NSColor.darkGray : NSColor.lightGray
        bgColor.setFill()
        roundedPath.fill()

        // Draw border for status indication
        if isInMeeting {
            NSColor.systemOrange.setStroke()
            roundedPath.lineWidth = borderWidth
            roundedPath.stroke()
        } else if isUnavailable {
            NSColor.systemGray.setStroke()
            roundedPath.lineWidth = borderWidth
            roundedPath.stroke()
        }

        // Draw initial letter
        let initial = String(name.prefix(1)).uppercased()
        let font = NSFont.systemFont(ofSize: size * 0.6, weight: .medium)
        let textColor = isDarkMode ? NSColor.white : NSColor.black
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: isUnavailable ? textColor.withAlphaComponent(0.5) : textColor,
        ]
        let textSize = initial.size(withAttributes: attributes)
        let textPoint = NSPoint(
            x: point.x + (size - textSize.width) / 2,
            y: point.y + (size - textSize.height) / 2
        )
        initial.draw(at: textPoint, withAttributes: attributes)
    }

    private func displayInitialsFallback(
        button: NSStatusBarButton, users: [SlackPresenceMonitor.UserPhotoInfo]
    ) {
        let attributed = NSMutableAttributedString()
        let baseAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12)
        ]
        let meetingAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]
        let unavailableAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .underlineStyle:
                (NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue),
        ]
        for user in users {
            let initial = String(user.name.prefix(1)).uppercased()
            let attrs: [NSAttributedString.Key: Any]
            if user.isInMeeting {
                attrs = meetingAttributes
            } else if user.isUnavailable {
                attrs = unavailableAttributes
            } else {
                attrs = baseAttributes
            }
            attributed.append(NSAttributedString(string: initial, attributes: attrs))
        }
        attributed.append(NSAttributedString(string: " ", attributes: baseAttributes))
        button.attributedTitle = attributed
    }

    private func createImageWithActivityDot(baseImage: NSImage) -> NSImage {
        let dotSize: CGFloat = 4
        let baseSize = baseImage.size

        let compositeImage = NSImage(size: baseSize)
        compositeImage.lockFocus()

        // Draw the base image tinted for current appearance
        let tintColor: NSColor =
            NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? .white : .black
        let tintedImage = baseImage.copy() as! NSImage
        tintedImage.lockFocus()
        tintColor.set()
        NSRect(origin: .zero, size: baseSize).fill(using: .sourceAtop)
        tintedImage.unlockFocus()

        tintedImage.draw(in: NSRect(origin: .zero, size: baseSize))

        // Draw green dot in lower right corner
        let dotX = baseSize.width - dotSize + 1
        let dotY: CGFloat = -1
        let dotRect = NSRect(x: dotX, y: dotY, width: dotSize, height: dotSize)
        NSColor.systemGreen.setFill()
        NSBezierPath(ovalIn: dotRect).fill()

        compositeImage.unlockFocus()
        compositeImage.isTemplate = false
        return compositeImage
    }

    private func updatePauseMenuItem() {
        let isPaused = ActivityTracker.shared.isPaused
        pauseMenuItem.title = isPaused ? "Resume Tracking" : "Pause Tracking"
    }

    private func updateSettingsMenuStates() {
        updateIdleSubmenu()
        updateTargetSubmenu()
        updateToggleSubmenu(
            at: 4, currentValue: ActivityTracker.shared.windDownMinutes,
            presets: presetWindDownMinutes, formatTitle: { "\($0) min before" },
            action: #selector(setWindDownTiming(_:)))
        updateToggleSubmenu(
            at: 5, currentValue: ActivityTracker.shared.eyeBreakIntervalMinutes,
            presets: presetEyeBreakIntervals, formatTitle: { "\($0) min" },
            action: #selector(setEyeBreakInterval(_:)))
        updateToggleSubmenu(
            at: 9, currentValue: ActivityTracker.shared.sunsetAlertMinutes,
            presets: presetSunsetAlertMinutes, formatTitle: { "\($0) min before" },
            action: #selector(setSunsetAlertTiming(_:)))
        updateSlackSubmenu()
    }

    private func updateSlackSubmenu() {
        // Slack Presence submenu is at index 12
        guard let slackItem = settingsSubmenu.item(at: 12),
            let slackSubmenu = slackItem.submenu
        else { return }
        slackItem.state = SlackPresenceMonitor.shared.isEnabled ? .on : .off
        // Update Enabled toggle state
        if let enabledItem = slackSubmenu.item(at: 0) {
            enabledItem.state = SlackPresenceMonitor.shared.isEnabled ? .on : .off
        }
        // Update Require App Open toggle state
        if let requireAppItem = slackSubmenu.item(at: 1) {
            requireAppItem.state = SlackPresenceMonitor.shared.requireSlackApp ? .on : .off
        }
        // Update Show Meeting Status toggle state
        if let meetingStatusItem = slackSubmenu.item(at: 2) {
            meetingStatusItem.state = SlackPresenceMonitor.shared.showMeetingStatus ? .on : .off
        }
    }

    private func updateIdleSubmenu() {
        guard let idleSubmenu = settingsSubmenu.item(at: 0)?.submenu else { return }
        updateSubmenuCheckmarks(
            submenu: idleSubmenu,
            currentValue: Int(ActivityTracker.shared.idleThreshold),
            presets: presetIdleThresholds,
            formatTitle: formatIdleThreshold,
            action: #selector(setIdleThreshold(_:)))
    }

    private func updateTargetSubmenu() {
        guard let targetSubmenu = settingsSubmenu.item(at: 1)?.submenu else { return }
        updateSubmenuCheckmarks(
            submenu: targetSubmenu,
            currentValue: ActivityTracker.shared.targetWorkDaySeconds,
            presets: presetDurations.map { $0.seconds },
            formatTitle: formatDuration,
            action: #selector(setTargetWorkDayDuration(_:)))
    }

    private func updateToggleSubmenu(
        at index: Int, currentValue: Int, presets: [Int],
        formatTitle: @escaping (Int) -> String, action: Selector
    ) {
        guard let item = settingsSubmenu.item(at: index),
            let submenu = item.submenu
        else { return }
        item.state = currentValue > 0 ? .on : .off
        updateDurationSubmenuCheckmarks(
            submenu: submenu, currentValue: currentValue, presets: presets,
            formatTitle: formatTitle, action: action)
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

    private func updateDurationSubmenuCheckmarks(
        submenu: NSMenu,
        currentValue: Int,
        presets: [Int],
        formatTitle: (Int) -> String,
        action: Selector
    ) {
        // Handle disabled (0) and preset values
        let allValues = [0] + presets
        let isKnownValue = allValues.contains(currentValue)

        // Remove existing custom value items (tag -1)
        let itemsToRemove = submenu.items
            .enumerated()
            .reversed()
            .filter { $0.element.tag == -1 && $0.element.action == action }
        for item in itemsToRemove {
            submenu.removeItem(at: item.offset)
        }

        // Update checkmarks for all items
        for item in submenu.items where item.action == action {
            item.state = item.tag == currentValue ? .on : .off
        }

        // Add custom value if not a known value
        guard !isKnownValue && currentValue > 0 else { return }

        let customItem = createMenuItem(title: formatTitle(currentValue), action: action)
        customItem.tag = -1
        customItem.state = .on
        customItem.representedObject = currentValue

        // Find position after the separator (after "Disabled")
        var insertIndex = submenu.items.count - 2  // Before last separator and Custom...
        for (index, item) in submenu.items.enumerated() {
            if item.tag > 0 && item.tag > currentValue {
                insertIndex = index
                break
            }
        }
        submenu.insertItem(customItem, at: insertIndex)
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

    @objc private func togglePreventSleep(_ sender: NSMenuItem) {
        if IdleDetector.shared.isCaffeinateActive {
            IdleDetector.shared.stopCaffeinate()
            EmojiFlashController.shared.hidePermanent()
            sender.state = .off
        } else {
            IdleDetector.shared.startCaffeinate()
            EmojiFlashController.shared.showPermanent(emoji: "☕️")
            sender.state = .on
        }
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

    @objc private func toggleStretchBreak(_ sender: NSMenuItem) {
        ActivityTracker.shared.stretchBreakEnabled.toggle()
        sender.state = ActivityTracker.shared.stretchBreakEnabled ? .on : .off
    }

    @objc private func togglePostZoomStretch(_ sender: NSMenuItem) {
        ActivityTracker.shared.postZoomStretchEnabled.toggle()
        sender.state = ActivityTracker.shared.postZoomStretchEnabled ? .on : .off
    }

    @objc private func setWindDownTiming(_ sender: NSMenuItem) {
        let minutes = sender.tag == -1 ? (sender.representedObject as? Int ?? 20) : sender.tag
        ActivityTracker.shared.windDownMinutes = minutes
        updateSettingsMenuStates()
    }

    @objc private func showCustomWindDownTimingInput() {
        let currentMinutes = ActivityTracker.shared.windDownMinutes
        showCustomInput(
            title: "Set Wrap-Up Timing",
            message: "Enter minutes before goal to show reminder:",
            currentValue: String(currentMinutes),
            validate: { Int($0).flatMap { $0 > 0 && $0 <= 120 ? $0 : nil } },
            onConfirm: { [weak self] minutes in
                ActivityTracker.shared.windDownMinutes = minutes
                self?.updateSettingsMenuStates()
            }
        )
    }

    @objc private func setSunsetAlertTiming(_ sender: NSMenuItem) {
        let minutes = sender.tag == -1 ? (sender.representedObject as? Int ?? 30) : sender.tag
        ActivityTracker.shared.sunsetAlertMinutes = minutes
        updateSettingsMenuStates()
    }

    @objc private func showCustomSunsetAlertTimingInput() {
        let currentMinutes = ActivityTracker.shared.sunsetAlertMinutes
        showCustomInput(
            title: "Set Sunset Alert Timing",
            message: "Enter minutes before sunset to show alert:",
            currentValue: String(currentMinutes),
            validate: { Int($0).flatMap { $0 > 0 && $0 <= 180 ? $0 : nil } },
            onConfirm: { [weak self] minutes in
                ActivityTracker.shared.sunsetAlertMinutes = minutes
                self?.updateSettingsMenuStates()
            }
        )
    }

    @objc private func showLocationInput() {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "Set Location"
        alert.informativeText = "Enter coordinates for sunset calculation:"
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        let containerView = NSView(frame: NSRect(x: 0, y: 0, width: 250, height: 70))

        let latLabel = NSTextField(labelWithString: "Latitude:")
        latLabel.frame = NSRect(x: 0, y: 46, width: 70, height: 17)

        let latField = NSTextField(frame: NSRect(x: 75, y: 44, width: 175, height: 22))
        latField.stringValue = String(format: "%.4f", SunsetCalculator.shared.latitude)
        latField.placeholderString = "e.g., 37.7749"

        let lonLabel = NSTextField(labelWithString: "Longitude:")
        lonLabel.frame = NSRect(x: 0, y: 14, width: 70, height: 17)

        let lonField = NSTextField(frame: NSRect(x: 75, y: 12, width: 175, height: 22))
        lonField.stringValue = String(format: "%.4f", SunsetCalculator.shared.longitude)
        lonField.placeholderString = "e.g., -122.4194"

        containerView.addSubview(latLabel)
        containerView.addSubview(latField)
        containerView.addSubview(lonLabel)
        containerView.addSubview(lonField)

        alert.accessoryView = containerView
        alert.window.initialFirstResponder = latField

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        guard let lat = Double(latField.stringValue.trimmingCharacters(in: .whitespaces)),
            let lon = Double(lonField.stringValue.trimmingCharacters(in: .whitespaces)),
            lat >= -90 && lat <= 90,
            lon >= -180 && lon <= 180
        else { return }

        SunsetCalculator.shared.latitude = lat
        SunsetCalculator.shared.longitude = lon
    }

    @objc private func setEyeBreakInterval(_ sender: NSMenuItem) {
        let minutes = sender.tag == -1 ? (sender.representedObject as? Int ?? 20) : sender.tag
        ActivityTracker.shared.eyeBreakIntervalMinutes = minutes
        updateSettingsMenuStates()
    }

    @objc private func showCustomEyeBreakIntervalInput() {
        let currentMinutes = ActivityTracker.shared.eyeBreakIntervalMinutes
        showCustomInput(
            title: "Set Eye Break Interval",
            message: "Enter interval in minutes (e.g., 20):",
            currentValue: String(currentMinutes),
            validate: { Int($0).flatMap { $0 > 0 && $0 <= 120 ? $0 : nil } },
            onConfirm: { [weak self] minutes in
                ActivityTracker.shared.eyeBreakIntervalMinutes = minutes
                self?.updateSettingsMenuStates()
            }
        )
    }

    @objc private func toggleSlackEnabled(_ sender: NSMenuItem) {
        SlackPresenceMonitor.shared.isEnabled.toggle()
        sender.state = SlackPresenceMonitor.shared.isEnabled ? .on : .off
        // Update parent submenu checkmark
        settingsSubmenu.item(at: 12)?.state = SlackPresenceMonitor.shared.isEnabled ? .on : .off
    }

    @objc private func toggleSlackRequireApp(_ sender: NSMenuItem) {
        SlackPresenceMonitor.shared.requireSlackApp.toggle()
        sender.state = SlackPresenceMonitor.shared.requireSlackApp ? .on : .off
    }

    @objc private func toggleShowMeetingStatus(_ sender: NSMenuItem) {
        SlackPresenceMonitor.shared.showMeetingStatus.toggle()
        sender.state = SlackPresenceMonitor.shared.showMeetingStatus ? .on : .off
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
            title: "Set Daily Hours Goal",
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

        // Validate credentials before saving
        Task {
            do {
                let teamName = try await SlackPresenceMonitor.shared.validateCredentials(
                    cookie: cookie, token: token)
                await MainActor.run {
                    // Save credentials on success
                    SlackPresenceMonitor.shared.cookie = cookie
                    SlackPresenceMonitor.shared.token = token
                    SlackPresenceMonitor.shared.reconnect()

                    // Show success message
                    let successAlert = NSAlert()
                    successAlert.messageText = "Credentials Validated"
                    successAlert.informativeText = "Successfully connected to \(teamName)"
                    successAlert.alertStyle = .informational
                    successAlert.addButton(withTitle: "OK")
                    successAlert.runModal()
                }
            } catch {
                await MainActor.run {
                    // Show error message
                    let errorAlert = NSAlert()
                    errorAlert.messageText = "Invalid Credentials"
                    errorAlert.informativeText = error.localizedDescription
                    errorAlert.alertStyle = .critical
                    errorAlert.addButton(withTitle: "OK")
                    errorAlert.runModal()
                }
            }
        }
    }

    @objc private func showSlackCoworkersInput() {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "Slack User IDs"
        alert.informativeText =
            "Enter one coworker per line (format: ID:Name):\ne.g., U01ABC:Alice\n\nTip: Use \"Me\" as a name to show a green dot\nwhen you're active (instead of initials)."
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
            .sorted { $0.value.lowercased() < $1.value.lowercased() }
            .map { "\($0.key):\($0.value)" }
            .joined(separator: multiline ? "\n" : ",")
    }
}
