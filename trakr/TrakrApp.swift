import SwiftUI
import AppKit

@main
struct TrakrApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarController: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBarController = MenuBarController()
    }

    func applicationWillTerminate(_ notification: Notification) {
        ActivityTracker.shared.saveState()
    }
}
