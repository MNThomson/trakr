import AppKit

class ScreenOverlayController {

    // MARK: - Singleton

    static let shared = ScreenOverlayController()

    // MARK: - Properties

    private var overlayWindows: [NSWindow] = []
    private var closeButtonWindow: NSWindow?
    private var isShowing = false
    private var reappearTimer: Timer?

    /// How long to wait before showing the overlay again after dismissal
    private let reappearInterval: TimeInterval = 15 * 60  // 15 minutes

    /// Opacity of the overlay (0.0 = transparent, 1.0 = opaque)
    private let overlayOpacity: CGFloat = 0.55

    // MARK: - Initialization

    private init() {
        // Listen for screen configuration changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    deinit {
        reappearTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Public Methods

    func showOverlay() {
        guard !isShowing else { return }
        isShowing = true
        createOverlayWindows()
        createCloseButtonWindow()
    }

    func dismissOverlay() {
        guard isShowing else { return }
        removeAllWindows()
        isShowing = false
        scheduleReappearance()
    }

    func hideOverlayPermanently() {
        reappearTimer?.invalidate()
        reappearTimer = nil
        removeAllWindows()
        isShowing = false
    }

    // MARK: - Private Methods

    private func createOverlayWindows() {
        for window in overlayWindows {
            window.orderOut(nil)
        }
        overlayWindows.removeAll()

        for screen in NSScreen.screens {
            let window = createOverlayWindow(for: screen)
            overlayWindows.append(window)
            window.orderFrontRegardless()
        }
    }

    private func createOverlayWindow(for screen: NSScreen) -> NSWindow {
        let window = NSWindow(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        window.level = .floating
        window.backgroundColor = NSColor.black.withAlphaComponent(overlayOpacity)
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = true  // Click-through!
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]

        return window
    }

    private func createCloseButtonWindow() {
        closeButtonWindow?.orderOut(nil)

        guard let mainScreen = NSScreen.main else { return }

        let buttonSize: CGFloat = 32
        let padding: CGFloat = 20
        let windowFrame = NSRect(
            x: mainScreen.frame.maxX - buttonSize - padding,
            y: mainScreen.frame.maxY - buttonSize - padding,
            width: buttonSize,
            height: buttonSize
        )

        let window = NSWindow(
            contentRect: windowFrame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        window.level = .floating + 1  // Above the overlay
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]

        let closeButton = CloseButton(
            frame: NSRect(x: 0, y: 0, width: buttonSize, height: buttonSize))
        closeButton.onDismiss = { [weak self] in
            self?.dismissOverlay()
        }
        window.contentView = closeButton

        closeButtonWindow = window
        window.orderFrontRegardless()
    }

    private func removeAllWindows() {
        for window in overlayWindows {
            window.orderOut(nil)
        }
        overlayWindows.removeAll()

        closeButtonWindow?.orderOut(nil)
        closeButtonWindow = nil
    }

    private func scheduleReappearance() {
        reappearTimer?.invalidate()
        reappearTimer = Timer.scheduledTimer(
            withTimeInterval: reappearInterval,
            repeats: false
        ) { [weak self] _ in
            self?.showOverlay()
        }
    }

    @objc private func screensDidChange() {
        if isShowing {
            createOverlayWindows()
            createCloseButtonWindow()
        }
    }
}

// MARK: - Close Button View

private class CloseButton: NSView {

    var onDismiss: (() -> Void)?
    private var isHovered = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupTrackingArea()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupTrackingArea()
    }

    private func setupTrackingArea() {
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let color =
            isHovered
            ? NSColor.white.withAlphaComponent(0.9)
            : NSColor.white.withAlphaComponent(0.5)

        if let image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close") {
            let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
            let symbolImage = image.withSymbolConfiguration(config) ?? image

            color.setFill()
            let imageRect = NSRect(
                x: (bounds.width - 16) / 2,
                y: (bounds.height - 16) / 2,
                width: 16,
                height: 16
            )
            symbolImage.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1.0)

            // Tint the image
            NSGraphicsContext.current?.cgContext.setBlendMode(.sourceAtop)
            color.setFill()
            imageRect.fill()
        }
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
        NSCursor.pointingHand.set()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
        NSCursor.arrow.set()
    }

    override func mouseDown(with event: NSEvent) {
        onDismiss?()
    }
}
