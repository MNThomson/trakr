import AppKit
import ServiceManagement
import SwiftUI

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
        enableLaunchAtLogin()
    }

    func applicationWillTerminate(_ notification: Notification) {
        ActivityTracker.shared.saveState()
    }

    private func enableLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
            }
        } catch {
            print("Failed to enable launch at login: \(error)")
        }
    }
}
