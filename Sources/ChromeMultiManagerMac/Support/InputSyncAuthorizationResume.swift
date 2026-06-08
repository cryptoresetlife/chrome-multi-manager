import Foundation

enum InputSyncAuthorizationResume {
    private static let skipCleanupKey = "inputSyncAuthorization.skipChromeCleanupOnNextQuit"
    private static let masterIDKey = "inputSyncAuthorization.masterID"
    private static let targetIDsKey = "inputSyncAuthorization.targetIDs"

    static func prepare(masterID: Int, targetIDs: [Int]) {
        let defaults = UserDefaults.standard
        defaults.set(masterID, forKey: masterIDKey)
        defaults.set(targetIDs, forKey: targetIDsKey)
        defaults.synchronize()
    }

    static var shouldSkipChromeCleanupOnQuit: Bool {
        UserDefaults.standard.bool(forKey: skipCleanupKey)
    }

    static func consumeSkipCleanupFlag() {
        UserDefaults.standard.removeObject(forKey: skipCleanupKey)
        UserDefaults.standard.synchronize()
    }

    static func pendingIDs() -> (masterID: Int, targetIDs: [Int])? {
        let defaults = UserDefaults.standard
        let masterID = defaults.integer(forKey: masterIDKey)
        let targetIDs = defaults.array(forKey: targetIDsKey) as? [Int] ?? []
        guard masterID > 0, !targetIDs.isEmpty else {
            return nil
        }
        return (masterID, targetIDs)
    }

    static func clearPending() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: skipCleanupKey)
        defaults.removeObject(forKey: masterIDKey)
        defaults.removeObject(forKey: targetIDsKey)
        defaults.synchronize()
    }
}
