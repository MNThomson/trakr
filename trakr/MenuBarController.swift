import AppKit
import Combine

class MenuBarController {

    // MARK: - Properties

    private var statusItem: NSStatusItem
    private var menu: NSMenu
    private var infoMenuItem: NSMenuItem
    private var cancellables = Set<AnyCancellable>()
    private var updateTimer: Timer?

    // MARK: - Initialization

    init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu = NSMenu()
        infoMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")

        setupStatusButton()
        setupMenu()
        setupObservers()
    }

    deinit {
        updateTimer?.invalidate()
    }

    // MARK: - Setup

    private func setupStatusButton() {
        guard let button = statusItem.button else { return }
        button.image = NSImage(
            systemSymbolName: "clock",
            accessibilityDescription: "Activity Timer"
        )
        button.image?.isTemplate = true
    }

    private func setupMenu() {
        infoMenuItem.isEnabled = false
        infoMenuItem.title = "⧖ \(ActivityTracker.shared.formattedActiveTime)"
        menu.addItem(infoMenuItem)
        menu.addItem(.separator())
        menu.addItem(createMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    private func createMenuItem(title: String, action: Selector, keyEquivalent: String = "") -> NSMenuItem {
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
    }

    // MARK: - UI Updates

    private func updateMenuItemTitle() {
        infoMenuItem.title = "⧖ \(ActivityTracker.shared.formattedActiveTime)"
    }

    // MARK: - Actions

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}
