import AppKit

class MenuBarController {

    private var statusItem: NSStatusItem
    private var menu: NSMenu

    init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu = NSMenu()

        setupStatusButton()
        setupMenu()
    }

    private func setupStatusButton() {
        guard let button = statusItem.button else { return }
        button.image = NSImage(
            systemSymbolName: "clock",
            accessibilityDescription: "Activity Timer"
        )
        button.image?.isTemplate = true
    }

    private func setupMenu() {
        menu.addItem(createMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func createMenuItem(title: String, action: Selector, keyEquivalent: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        return item
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}
