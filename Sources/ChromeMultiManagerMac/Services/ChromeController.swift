import AppKit
import ApplicationServices
import Darwin
import Foundation

enum ChromeControllerError: LocalizedError, Sendable {
    case chromeNotFound
    case launchFailed(String)
    case accessibilityDenied
    case appleScriptFailed(String)

    var errorDescription: String? {
        switch self {
        case .chromeNotFound:
            return "未找到 Google Chrome。请先安装 Chrome。"
        case .launchFailed(let message):
            return "启动失败: \(message)"
        case .accessibilityDenied:
            return "窗口排列失败：请在 系统设置 -> 隐私与安全性 -> 辅助功能 中给本 App 开启权限。"
        case .appleScriptFailed(let message):
            return "窗口排列失败: \(message)"
        }
    }
}

final class ChromeController: @unchecked Sendable {
    private let cdp = CdpClient()
    private var localProxies: [Int: LocalAuthProxy] = [:]
    private let proxyLock = NSLock()

    func findChrome() -> String? {
        let paths = [
            "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
            "\(NSHomeDirectory())/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
            "/Applications/Google Chrome Beta.app/Contents/MacOS/Google Chrome Beta",
            "/Applications/Google Chrome Canary.app/Contents/MacOS/Google Chrome Canary"
        ]
        if let found = paths.first(where: { FileManager.default.fileExists(atPath: $0) }) {
            return found
        }
        return which("google-chrome") ?? which("chrome")
    }

    func isRunning(_ profile: ChromeProfile) -> Bool {
        portOpen(profile.debugPort)
            || pidForDebugPort(profile.debugPort) != nil
            || pidForProfileDirectory(profile) != nil
    }

    func runningIDs(for profiles: [ChromeProfile]) -> Set<Int> {
        let processSnapshot = (try? processOutput("/bin/ps", ["-axo", "pid=,args=", "-ww"])) ?? ""
        return Set(profiles.compactMap { profile in
            if portOpen(profile.debugPort, timeout: 0.12) {
                return profile.id
            }
            if processSnapshot.contains("--remote-debugging-port=\(profile.debugPort)") {
                return profile.id
            }
            if processSnapshot.contains(AppPaths.storeDirectory(for: profile).path) {
                return profile.id
            }
            return nil
        })
    }

    func pidForDebugPort(_ port: Int) -> Int? {
        guard let output = try? processOutput("/bin/ps", ["-axo", "pid=,args=", "-ww"]) else { return nil }
        let needle = "--remote-debugging-port=\(port)"
        for line in output.split(separator: "\n") where line.contains(needle) {
            let parts = line.trimmingCharacters(in: .whitespaces).split(maxSplits: 1, whereSeparator: \.isWhitespace)
            if let first = parts.first, let pid = Int(first) {
                return pid
            }
        }
        return nil
    }

    func launch(_ profile: ChromeProfile, refreshBadge: Bool = false) throws -> ChromeProfile {
        AppLogger.info("launch requested id=\(profile.id) port=\(profile.debugPort) hasProxy=\(!profile.proxy.isEmpty)")
        if isRunning(profile) {
            try ensureLocalProxyIfNeeded(for: profile)
            var running = profile
            running.pid = pidForDebugPort(profile.debugPort) ?? profile.pid
            AppLogger.info("launch skipped already running id=\(profile.id) pid=\(running.pid.map(String.init) ?? "unknown")")
            return running
        }
        guard let chrome = findChrome() else {
            AppLogger.error("chrome not found for id=\(profile.id)")
            throw ChromeControllerError.chromeNotFound
        }
        try AppPaths.ensureDirectories()
        let storeDirectory = AppPaths.storeDirectory(for: profile)
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        cleanupStaleChromeLocks(in: storeDirectory)
        var args = [
            "--user-data-dir=\(storeDirectory.path)",
            "--remote-debugging-port=\(profile.debugPort)",
            "--no-first-run",
            "--no-default-browser-check"
        ]
        if let proxyArgument = try chromeProxyArgument(for: profile) {
            args.append("--proxy-server=\(proxyArgument)")
        }
        args.append("--new-window")
        args.append("about:blank")
        let launchedPID: Int
        do {
            launchedPID = try spawnDetached(executable: chrome, arguments: args)
            AppLogger.info("spawned chrome id=\(profile.id) pid=\(launchedPID) port=\(profile.debugPort)")
        } catch {
            AppLogger.error("spawn failed id=\(profile.id) error=\(error.localizedDescription)")
            throw ChromeControllerError.launchFailed(error.localizedDescription)
        }
        var updated = profile
        updated.pid = launchedPID
        for attempt in 0..<12 {
            Thread.sleep(forTimeInterval: 0.2)
            if isRunning(updated) {
                updated.pid = pidForDebugPort(updated.debugPort) ?? updated.pid
                if refreshBadge {
                    _ = cdp.updateBadge(profile: updated)
                }
                AppLogger.info("launch ready id=\(profile.id) port=\(profile.debugPort) pid=\(updated.pid.map(String.init) ?? "unknown") attempts=\(attempt + 1)")
                return updated
            }
        }
        AppLogger.info("launch dispatched id=\(profile.id) port=\(profile.debugPort); status will refresh later")
        return updated
    }

    func stop(_ profile: ChromeProfile) {
        AppLogger.info("stop requested id=\(profile.id) port=\(profile.debugPort)")
        let pid = pidForDebugPort(profile.debugPort) ?? pidForProfileDirectory(profile) ?? profile.pid
        if let pid {
            AppLogger.info("stopping id=\(profile.id) pid=\(pid)")
            Darwin.kill(pid_t(pid), SIGTERM)
            Thread.sleep(forTimeInterval: 0.25)
            if portOpen(profile.debugPort, timeout: 0.08) {
                Darwin.kill(pid_t(pid), SIGKILL)
                AppLogger.info("force killed id=\(profile.id) pid=\(pid)")
            }
        } else {
            AppLogger.info("stop skipped no pid id=\(profile.id)")
        }
        proxyLock.lock()
        localProxies[profile.id]?.stop()
        localProxies[profile.id] = nil
        proxyLock.unlock()
    }

    func stopAllProxies() {
        proxyLock.lock()
        let proxies = Array(localProxies.values)
        localProxies.removeAll()
        proxyLock.unlock()
        for proxy in proxies {
            proxy.stop()
        }
    }

    func stopAllManagedChromeProcesses() {
        let initialPIDs = managedChromeProcessPIDs()
        guard !initialPIDs.isEmpty else {
            stopAllProxies()
            return
        }

        AppLogger.info("stopping managed chrome process fallback count=\(initialPIDs.count)")
        for pid in initialPIDs {
            Darwin.kill(pid_t(pid), SIGTERM)
        }
        Thread.sleep(forTimeInterval: 0.45)

        let remainingPIDs = managedChromeProcessPIDs()
        for pid in remainingPIDs {
            Darwin.kill(pid_t(pid), SIGKILL)
            AppLogger.info("force killed managed chrome fallback pid=\(pid)")
        }
        stopAllProxies()
    }

    @discardableResult
    func ensureLocalProxies(for profiles: [ChromeProfile]) -> Int {
        var count = 0
        for profile in profiles where isRunning(profile) {
            do {
                if try ensureLocalProxyIfNeeded(for: profile) {
                    count += 1
                }
            } catch {
                AppLogger.error("failed ensuring local proxy id=\(profile.id) error=\(error.localizedDescription)")
            }
        }
        return count
    }

    func groupNavigate(profiles: [ChromeProfile], url: String) -> Int {
        var normalized = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return 0 }
        if !normalized.lowercased().hasPrefix("http://") && !normalized.lowercased().hasPrefix("https://") {
            normalized = "https://\(normalized)"
        }
        var count = 0
        for profile in profiles where isRunning(profile) {
            if cdp.navigate(port: profile.debugPort, url: normalized) {
                count += 1
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.8) {
            self.refreshBadges(profiles: profiles)
        }
        return count
    }

    func groupEvaluate(profiles: [ChromeProfile], script: String) -> Int {
        let trimmed = script.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        var count = 0
        for profile in profiles where isRunning(profile) {
            if cdp.evaluate(port: profile.debugPort, expression: trimmed) {
                count += 1
            }
        }
        refreshBadges(profiles: profiles)
        return count
    }

    func refreshBadges(profiles: [ChromeProfile]) {
        for profile in profiles where isRunning(profile) {
            _ = cdp.updateBadge(profile: profile)
        }
    }

    func arrangeWindows(profiles: [ChromeProfile], masterProfile: ChromeProfile? = nil) throws -> Int {
        let running = runningProfiles(from: profiles, masterProfile: masterProfile)
        guard !running.isEmpty else { return 0 }

        let masterBounds = masterProfile.flatMap { profile -> CdpWindowBounds? in
            guard isRunning(profile) else { return nil }
            return cdp.windowBounds(port: profile.debugPort)
        }
        let targetScreen = NSScreen.main ?? NSScreen.screens.first
        let visibleFrame = targetScreen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let layoutRect = visibleFrame.insetBy(dx: 8, dy: 8)
        let plan = makeArrangementPlan(
            count: running.count,
            visibleFrame: layoutRect,
            preferredSize: masterBounds.map { NSSize(width: $0.width, height: $0.height) }
        )
        guard plan.width > 0, plan.height > 0 else { return 0 }

        var arranged = 0
        for (index, profile) in running.enumerated() {
            let column = index % plan.columns
            let row = index / plan.columns
            let x = Int(round(layoutRect.minX)) + column * (plan.width + plan.gap)
            let y = appleScriptTopY(for: layoutRect) + row * (plan.height + plan.gap)
            if cdp.setWindowBounds(port: profile.debugPort, left: x, top: y, width: plan.width, height: plan.height) {
                arranged += 1
            } else {
                AppLogger.error("arrange skipped cdp failed id=\(profile.id) port=\(profile.debugPort)")
            }
        }
        AppLogger.info(
            "arranged windows count=\(arranged)/\(running.count) mode=cdp columns=\(plan.columns) rows=\(plan.rows) size=\(plan.width)x\(plan.height) master=\(masterProfile.map { String($0.id) } ?? "none")"
        )
        return arranged
    }

    func importProxyProfiles(from fileURL: URL, startID: Int) throws -> [ChromeProfile] {
        let content = try String(contentsOf: fileURL, encoding: .utf8)
        var profiles: [ChromeProfile] = []
        var nextID = startID
        for rawLine in content.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let parts = line.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 4 else { continue }
            let host = parts[0]
            let port = parts[1]
            let user = parts[2]
            let password = parts.dropFirst(3).joined(separator: ":")
            let escapedUser = user.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) ?? user
            let escapedPassword = password.addingPercentEncoding(withAllowedCharacters: .urlPasswordAllowed) ?? password
            var profile = ChromeProfile.blank(id: nextID)
            profile.proxy = "http://\(escapedUser):\(escapedPassword)@\(host):\(port)"
            profiles.append(profile)
            nextID += 1
        }
        return profiles
    }

    private func chromeProxyArgument(for profile: ChromeProfile) throws -> String? {
        let proxy = profile.proxy.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !proxy.isEmpty else { return nil }
        if let parsed = parseAuthProxy(proxy) {
            let localPort = try startLocalProxy(profileID: profile.id, upstream: parsed)
            return "http://127.0.0.1:\(localPort)"
        }
        return proxy.contains("://") ? proxy : "http://\(proxy)"
    }

    @discardableResult
    private func ensureLocalProxyIfNeeded(for profile: ChromeProfile) throws -> Bool {
        let proxy = profile.proxy.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !proxy.isEmpty, let parsed = parseAuthProxy(proxy) else {
            return false
        }
        _ = try startLocalProxy(profileID: profile.id, upstream: parsed, restartExisting: false)
        return true
    }

    private func startLocalProxy(profileID: Int, upstream: AuthProxy, restartExisting: Bool = true) throws -> UInt16 {
        let localPort = UInt16(20000 + profileID)
        proxyLock.lock()
        if let existing = localProxies[profileID] {
            if !restartExisting {
                proxyLock.unlock()
                return localPort
            }
            existing.stop()
            localProxies[profileID] = nil
        }
        let localProxy = LocalAuthProxy(localPort: localPort, upstream: upstream)
        do {
            try localProxy.start()
            localProxies[profileID] = localProxy
            proxyLock.unlock()
            AppLogger.info("local auth proxy ready id=\(profileID) localPort=\(localPort)")
            return localPort
        } catch {
            proxyLock.unlock()
            AppLogger.error("local auth proxy failed id=\(profileID) localPort=\(localPort) error=\(error.localizedDescription)")
            throw error
        }
    }

    private func pidForProfileDirectory(_ profile: ChromeProfile) -> Int? {
        guard let output = try? processOutput("/bin/ps", ["-axo", "pid=,args=", "-ww"]) else { return nil }
        let storePath = AppPaths.storeDirectory(for: profile).path
        for line in output.split(separator: "\n") where line.contains(storePath) {
            let parts = line.trimmingCharacters(in: .whitespaces).split(maxSplits: 1, whereSeparator: \.isWhitespace)
            if let first = parts.first, let pid = Int(first) {
                return pid
            }
        }
        return nil
    }

    private func managedChromeProcessPIDs() -> Set<Int> {
        guard let output = try? processOutput("/bin/ps", ["-axo", "pid=,args=", "-ww"]) else {
            return []
        }
        let profileRoot = AppPaths.profileDirectory.path + "/"
        return Set(output.split(separator: "\n").compactMap { line -> Int? in
            guard line.contains(profileRoot),
                  line.contains("--user-data-dir="),
                  line.contains("/Contents/MacOS/Google Chrome") else {
                return nil
            }
            let parts = line.trimmingCharacters(in: .whitespaces).split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard let first = parts.first else { return nil }
            return Int(first)
        })
    }

    private func cleanupStaleChromeLocks(in directory: URL) {
        let lockNames = ["SingletonLock", "SingletonCookie", "SingletonSocket"]
        for name in lockNames {
            let url = directory.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            do {
                try FileManager.default.removeItem(at: url)
                AppLogger.info("removed stale chrome lock \(url.path)")
            } catch {
                AppLogger.error("failed removing chrome lock \(url.path): \(error.localizedDescription)")
            }
        }
    }

    private struct RunningProfile {
        let profile: ChromeProfile
        let pid: Int
    }

    private struct ArrangementPlan {
        let columns: Int
        let rows: Int
        let width: Int
        let height: Int
        let gap: Int
    }

    private func runningProfilesWithPIDs(from profiles: [ChromeProfile], masterProfile: ChromeProfile?) -> [RunningProfile] {
        let running = profiles.compactMap { profile -> RunningProfile? in
            guard isRunning(profile),
                  let pid = pidForDebugPort(profile.debugPort) ?? profile.pid else {
                return nil
            }
            return RunningProfile(profile: profile, pid: pid)
        }
        guard let masterProfile,
              let master = running.first(where: { $0.profile.id == masterProfile.id }) else {
            return running
        }
        return [master] + running.filter { $0.profile.id != master.profile.id }
    }

    private func runningProfiles(from profiles: [ChromeProfile], masterProfile: ChromeProfile?) -> [ChromeProfile] {
        let running = profiles.filter { isRunning($0) }
        guard let masterProfile,
              let master = running.first(where: { $0.id == masterProfile.id }) else {
            return running
        }
        return [master] + running.filter { $0.id != master.id }
    }

    private func makeArrangementPlan(count: Int, visibleFrame: NSRect, preferredSize: NSSize?) -> ArrangementPlan {
        let gap = 8
        let minimumWidth = 360
        let minimumHeight = 260
        let maximumWidth = max(minimumWidth, Int(visibleFrame.width))
        let maximumHeight = max(minimumHeight, Int(visibleFrame.height))
        let preferred = preferredSize.map { size in
            NSSize(
                width: min(max(size.width, CGFloat(minimumWidth)), CGFloat(maximumWidth)),
                height: min(max(size.height, CGFloat(minimumHeight)), CGFloat(maximumHeight))
            )
        }
        var best: (columns: Int, rows: Int, width: Int, height: Int, score: Double)?
        for columns in 1...max(count, 1) {
            let rows = Int(ceil(Double(count) / Double(columns)))
            let availableWidth = max(1, Double(visibleFrame.width) - Double(gap * (columns - 1)))
            let availableHeight = max(1, Double(visibleFrame.height) - Double(gap * (rows - 1)))
            let cellWidth = floor(availableWidth / Double(columns))
            let cellHeight = floor(availableHeight / Double(rows))
            guard cellWidth > 0, cellHeight > 0 else { continue }

            let width: Double
            let height: Double
            let score: Double
            if let preferred {
                let scale = min(1, cellWidth / preferred.width, cellHeight / preferred.height)
                width = max(1, floor(preferred.width * scale))
                height = max(1, floor(preferred.height * scale))
                let unusedColumns = Double((columns * rows) - count)
                score = scale * 10_000 + min(width, cellWidth) * min(height, cellHeight) / 1_000 - unusedColumns * 8
            } else {
                width = cellWidth
                height = cellHeight
                let aspect = width / max(height, 1)
                let aspectPenalty = abs(log(aspect / 1.45)) * 180
                let tooSmallPenalty = max(0, Double(minimumWidth) - width) + max(0, Double(minimumHeight) - height)
                let unusedColumns = Double((columns * rows) - count)
                score = width * height / 1_000 - aspectPenalty - tooSmallPenalty * 2 - unusedColumns * 6
            }
            if best == nil || score > best!.score {
                best = (columns, rows, Int(width), Int(height), score)
            }
        }
        let fallbackColumns = max(1, Int(ceil(sqrt(Double(count)))))
        let fallbackRows = Int(ceil(Double(count) / Double(fallbackColumns)))
        let result = best ?? (
            columns: fallbackColumns,
            rows: fallbackRows,
            width: max(1, Int(visibleFrame.width) / fallbackColumns),
            height: max(1, Int(visibleFrame.height) / fallbackRows),
            score: 0
        )
        return ArrangementPlan(
            columns: result.columns,
            rows: result.rows,
            width: result.width,
            height: result.height,
            gap: gap
        )
    }

    private func windowFrame(forPID pid: Int) -> NSRect? {
        guard let window = firstWindowElement(forPID: pid),
              let position = axPoint(window, attribute: kAXPositionAttribute),
              let size = axSize(window, attribute: kAXSizeAttribute) else {
            return nil
        }
        let y = referenceMaxYForAppleScript() - position.y - size.height
        return NSRect(x: position.x, y: y, width: size.width, height: size.height)
    }

    private func setWindowFrame(forPID pid: Int, x: Int, y: Int, width: Int, height: Int) -> Bool {
        guard let window = firstWindowElement(forPID: pid) else {
            AppLogger.error("arrange skipped no accessible window pid=\(pid)")
            return false
        }
        var targetSize = CGSize(width: width, height: height)
        var targetPosition = CGPoint(x: x, y: y)
        guard let sizeValue = AXValueCreate(.cgSize, &targetSize),
              let positionValue = AXValueCreate(.cgPoint, &targetPosition) else {
            return false
        }
        let sizeResult = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        let positionResult = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue)
        if sizeResult != .success || positionResult != .success {
            AppLogger.error("arrange failed pid=\(pid) sizeResult=\(sizeResult.rawValue) positionResult=\(positionResult.rawValue)")
            return false
        }
        return true
    }

    private func firstWindowElement(forPID pid: Int) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid_t(pid))
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
        guard result == .success,
              let windows = value as? [AXUIElement],
              let window = windows.first else {
            return nil
        }
        return window
    }

    private func axPoint(_ element: AXUIElement, attribute: String) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let axValue = value,
              CFGetTypeID(axValue) == AXValueGetTypeID() else {
            return nil
        }
        var point = CGPoint.zero
        guard AXValueGetValue((axValue as! AXValue), .cgPoint, &point) else {
            return nil
        }
        return point
    }

    private func axSize(_ element: AXUIElement, attribute: String) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let axValue = value,
              CFGetTypeID(axValue) == AXValueGetTypeID() else {
            return nil
        }
        var size = CGSize.zero
        guard AXValueGetValue((axValue as! AXValue), .cgSize, &size) else {
            return nil
        }
        return size
    }

    private func ensureAccessibilityTrusted() throws {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else {
            throw ChromeControllerError.accessibilityDenied
        }
    }

    private func screenContaining(windowFrame: NSRect) -> NSScreen? {
        let center = NSPoint(x: windowFrame.midX, y: windowFrame.midY)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) {
            return screen
        }
        return NSScreen.screens.max { lhs, rhs in
            lhs.frame.intersection(windowFrame).width * lhs.frame.intersection(windowFrame).height <
                rhs.frame.intersection(windowFrame).width * rhs.frame.intersection(windowFrame).height
        }
    }

    private func appleScriptTopY(for appKitRect: NSRect) -> Int {
        Int(round(referenceMaxYForAppleScript() - appKitRect.maxY))
    }

    private func referenceMaxYForAppleScript() -> CGFloat {
        NSScreen.screens.first?.frame.maxY ?? NSScreen.main?.frame.maxY ?? 0
    }

    private func spawnDetached(executable: String, arguments: [String]) throws -> Int {
        var argv = ([executable] + arguments).map { strdup($0) }
        argv.append(nil)
        defer {
            for pointer in argv where pointer != nil {
                free(pointer)
            }
        }

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        let devNull = open("/dev/null", O_WRONLY)
        if devNull >= 0 {
            posix_spawn_file_actions_adddup2(&fileActions, devNull, STDOUT_FILENO)
            posix_spawn_file_actions_adddup2(&fileActions, devNull, STDERR_FILENO)
            posix_spawn_file_actions_addclose(&fileActions, devNull)
        }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))

        var pid = pid_t()
        let result = posix_spawn(&pid, executable, &fileActions, &attributes, argv, environ)
        if devNull >= 0 {
            close(devNull)
        }
        guard result == 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(result),
                userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(result))]
            )
        }
        return Int(pid)
    }

    private func parseAuthProxy(_ proxy: String) -> AuthProxy? {
        let normalized = proxy.contains("://") ? proxy : "http://\(proxy)"
        guard let components = URLComponents(string: normalized),
              let host = components.host,
              let port = components.port,
              let user = components.user,
              let password = components.password,
              let upstreamPort = UInt16(exactly: port) else {
            return nil
        }
        return AuthProxy(
            host: host,
            port: upstreamPort,
            username: user.removingPercentEncoding ?? user,
            password: password.removingPercentEncoding ?? password
        )
    }

    private func portOpen(_ port: Int, timeout: TimeInterval = 0.18) -> Bool {
        guard port > 0, port <= Int(UInt16.max) else { return false }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        let existingFlags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, existingFlags | O_NONBLOCK)

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        inet_pton(AF_INET, "127.0.0.1", &address.sin_addr)

        let connectResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                connect(fd, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if connectResult == 0 {
            return true
        }
        guard errno == EINPROGRESS else {
            return false
        }

        var pollFD = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let timeoutMS = max(1, Int32(timeout * 1000))
        guard poll(&pollFD, 1, timeoutMS) > 0 else {
            return false
        }

        var socketError: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        let optionResult = withUnsafeMutablePointer(to: &socketError) { errorPointer in
            getsockopt(fd, SOL_SOCKET, SO_ERROR, errorPointer, &length)
        }
        return optionResult == 0 && socketError == 0
    }

    private func which(_ executable: String) -> String? {
        guard let output = try? processOutput("/usr/bin/which", [executable]) else { return nil }
        let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    private func processOutput(_ path: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: output.trimmingCharacters(in: .whitespacesAndNewlines)]
            )
        }
        return output
    }
}
