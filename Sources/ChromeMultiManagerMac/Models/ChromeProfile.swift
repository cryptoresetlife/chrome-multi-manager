import Foundation

struct ChromeProfile: Identifiable, Codable, Hashable, Sendable {
    var id: Int
    var name: String
    var group: String
    var proxy: String
    var note: String
    var pid: Int?
    var debugPort: Int

    static func nextDebugPort(for id: Int) -> Int {
        19000 + id
    }

    static func blank(id: Int) -> ChromeProfile {
        ChromeProfile(
            id: id,
            name: "账号\(id)",
            group: "默认",
            proxy: "",
            note: "",
            pid: nil,
            debugPort: nextDebugPort(for: id)
        )
    }
}

struct RuntimeStatus {
    var runningIDs: Set<Int> = []

    func isRunning(_ profile: ChromeProfile) -> Bool {
        runningIDs.contains(profile.id)
    }
}
