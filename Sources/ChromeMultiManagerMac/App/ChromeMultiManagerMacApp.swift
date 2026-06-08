import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var didRunTerminationCleanup = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        InputSyncAuthorizationResume.consumeSkipCleanupFlag()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        InputSyncAuthorizationResume.clearPending()
        closeManagedChromeWindows()
        return .terminateNow
    }

    private func closeManagedChromeWindows() {
        guard !didRunTerminationCleanup else { return }
        didRunTerminationCleanup = true

        let profiles = loadProfilesForShutdown()
        guard !profiles.isEmpty else { return }

        AppLogger.info("app terminating; closing managed chrome profiles count=\(profiles.count)")
        let controller = ChromeController()
        for profile in profiles {
            controller.stop(profile)
        }
        controller.stopAllManagedChromeProcesses()
        AppLogger.info("app termination cleanup finished")
    }

    private func loadProfilesForShutdown() -> [ChromeProfile] {
        do {
            try AppPaths.ensureDirectories()
            guard FileManager.default.fileExists(atPath: AppPaths.configFile.path) else {
                return []
            }
            let data = try Data(contentsOf: AppPaths.configFile)
            return try JSONDecoder().decode([ChromeProfile].self, from: data).map { profile in
                var fixed = profile
                if fixed.debugPort == 0 {
                    fixed.debugPort = ChromeProfile.nextDebugPort(for: fixed.id)
                }
                return fixed
            }
        } catch {
            AppLogger.error("failed loading profiles for termination cleanup error=\(error.localizedDescription)")
            return []
        }
    }
}

@main
struct ChromeMultiManagerMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 1000, minHeight: 620)
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
    }
}
