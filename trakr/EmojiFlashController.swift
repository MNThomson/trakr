import AppKit

/// Displays a semi-transparent emoji flash in the upper-left corner of the screen
class EmojiFlashController {

    // MARK: - Singleton

    static let shared = EmojiFlashController()

    // MARK: - Constants

    private let fadeInDuration: TimeInterval = 0.5
    private let stayDuration: TimeInterval = 2.0
    private let fadeOutDuration: TimeInterval = 1.0
    private let windowSize: CGFloat = 150
    private let emojiSize: CGFloat = 80
    private let backgroundOpacity: CGFloat = 0.5
    private let cornerRadius: CGFloat = 20
    private let padding: CGFloat = 20

    // MARK: - Properties

    private var flashWindow: NSWindow?
    private var dismissTimer: Timer?

    // MARK: - Initialization

    private init() {}

    // MARK: - Public Methods

    /// Flash an emoji in the upper-left corner of the main screen
    func flash(emoji: String) {
        // Cancel any existing flash
        dismissTimer?.invalidate()
        flashWindow?.orderOut(nil)

        guard let screen = NSScreen.main else { return }

        // Position in upper-left corner with padding
        let windowFrame = NSRect(
            x: screen.visibleFrame.minX + padding,
            y: screen.visibleFrame.maxY - windowSize - padding,
            width: windowSize,
            height: windowSize
        )

        let window = NSWindow(
            contentRect: windowFrame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        window.level = .floating
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]
        window.alphaValue = 0.0  // Start invisible for fade-in

        // Create the emoji view
        let contentView = EmojiFlashView(
            frame: NSRect(x: 0, y: 0, width: windowSize, height: windowSize),
            emoji: emoji,
            emojiSize: emojiSize,
            backgroundOpacity: backgroundOpacity,
            cornerRadius: cornerRadius
        )
        window.contentView = contentView

        flashWindow = window
        window.orderFrontRegardless()

        // Fade in
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = fadeInDuration
            window.animator().alphaValue = 1.0
        })

        // Schedule fade-out after fade-in + stay duration
        dismissTimer = Timer.scheduledTimer(
            withTimeInterval: fadeInDuration + stayDuration,
            repeats: false
        ) { [weak self] _ in
            self?.fadeOutAndDismiss()
        }
    }

    // MARK: - Private Methods

    private func fadeOutAndDismiss() {
        guard let window = flashWindow else { return }

        NSAnimationContext.runAnimationGroup(
            { context in
                context.duration = fadeOutDuration
                window.animator().alphaValue = 0.0
            },
            completionHandler: { [weak self] in
                self?.flashWindow?.orderOut(nil)
                self?.flashWindow = nil
            })
    }
}

// MARK: - Emoji Flash View

private class EmojiFlashView: NSView {

    private let emoji: String
    private let emojiSize: CGFloat
    private let backgroundOpacity: CGFloat
    private let cornerRadius: CGFloat

    init(
        frame: NSRect, emoji: String, emojiSize: CGFloat, backgroundOpacity: CGFloat,
        cornerRadius: CGFloat
    ) {
        self.emoji = emoji
        self.emojiSize = emojiSize
        self.backgroundOpacity = backgroundOpacity
        self.cornerRadius = cornerRadius
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        // Draw rounded background
        let backgroundPath = NSBezierPath(
            roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius)
        NSColor.black.withAlphaComponent(backgroundOpacity).setFill()
        backgroundPath.fill()

        // Draw emoji centered
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: emojiSize),
            .paragraphStyle: paragraphStyle,
        ]

        let emojiString = NSAttributedString(string: emoji, attributes: attributes)
        let emojiRect = NSRect(
            x: 0,
            y: (bounds.height - emojiSize) / 2 - 5,
            width: bounds.width,
            height: emojiSize + 10
        )
        emojiString.draw(in: emojiRect)
    }
}
