import Foundation

enum AppPaths {
    static let appName = "ChromeMultiManager"

    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent(appName, isDirectory: true)
    }

    static var profileDirectory: URL {
        supportDirectory.appendingPathComponent("Profiles", isDirectory: true)
    }

    static var configFile: URL {
        supportDirectory.appendingPathComponent("config.json")
    }

    static var logFile: URL {
        supportDirectory.appendingPathComponent("ChromeMultiManagerMac.log")
    }

    static func ensureDirectories() throws {
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: profileDirectory, withIntermediateDirectories: true)
    }

    static func storeDirectory(for profile: ChromeProfile) -> URL {
        profileDirectory.appendingPathComponent(String(format: "profile_%03d", profile.id), isDirectory: true)
    }
}
