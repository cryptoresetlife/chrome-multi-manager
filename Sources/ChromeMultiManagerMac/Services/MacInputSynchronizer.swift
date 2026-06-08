import AppKit
import CoreGraphics
import Foundation

enum MacInputSyncError: LocalizedError {
    case noMasterProcess
    case pageUnavailable
    case eventTapDenied

    var errorDescription: String? {
        switch self {
        case .noMasterProcess:
            return "找不到主控 Chrome 进程，请先启动主控窗口。"
        case .pageUnavailable:
            return "无法连接主控页面，请刷新状态或重启主控窗口后再试。"
        case .eventTapDenied:
            return "无法创建全窗口同步监听，请确认“辅助功能”和“输入监控”权限已开启。"
        }
    }
}

enum InputSyncMode: String, Sendable {
    case system
    case page

    var title: String {
        switch self {
        case .system:
            return "全窗口同步"
        case .page:
            return "网页同步"
        }
    }
}

struct InputSyncPermissionStatus: Sendable {
    let canListenToInput: Bool
    let canPostEvents: Bool

    var canUseSystemMode: Bool {
        canListenToInput && canPostEvents
    }

    var missingItemsText: String {
        var items: [String] = []
        if !canListenToInput {
            items.append("输入监控")
        }
        if !canPostEvents {
            items.append("辅助功能")
        }
        return items.isEmpty ? "无" : items.joined(separator: "、")
    }
}

private enum CdpSyncEvent: Sendable {
    case mouse(type: String, ratioX: Double, ratioY: Double, button: String, buttons: Int, clickCount: Int, deltaX: Double, deltaY: Double, modifiers: Int)
    case text(String)
    case key(type: String, key: String, code: String, windowsVK: Int, modifiers: Int, autoRepeat: Bool)
    case navigate(String)
}

private enum SystemInputEvent: Sendable {
    case mouse(event: EventBox, ratioX: Double, ratioY: Double, flipForPosting: Bool)
    case key(event: EventBox)
}

private final class EventBox: @unchecked Sendable {
    let event: CGEvent

    init(_ event: CGEvent) {
        self.event = event
    }
}

private struct ManagedWindowFrame: Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    var area: Double { width * height }

    func normalizedPoint(_ point: CGPoint, displayHeight: Double) -> (ratioX: Double, ratioY: Double, flipped: Bool)? {
        if contains(point) {
            return (
                max(0, min(1, (point.x - x) / width)),
                max(0, min(1, (point.y - y) / height)),
                false
            )
        }
        let flipped = CGPoint(x: point.x, y: displayHeight - point.y)
        if contains(flipped) {
            return (
                max(0, min(1, (flipped.x - x) / width)),
                max(0, min(1, (flipped.y - y) / height)),
                true
            )
        }
        return nil
    }

    func point(ratioX: Double, ratioY: Double, displayHeight: Double, flipForPosting: Bool) -> CGPoint {
        let topLeftPoint = CGPoint(
            x: x + ratioX * width,
            y: y + ratioY * height
        )
        if flipForPosting {
            return CGPoint(x: topLeftPoint.x, y: displayHeight - topLeftPoint.y)
        }
        return topLeftPoint
    }

    private func contains(_ point: CGPoint) -> Bool {
        point.x >= x
            && point.x <= x + width
            && point.y >= y
            && point.y <= y + height
    }
}

private final class SystemInputSynchronizer: @unchecked Sendable {
    private static let relayedEventMarker: Int64 = 0x434D4D53594E43

    private let master: ChromeProfile
    private let targets: [ChromeProfile]
    private let pidResolver: @Sendable (Int) -> Int?
    private let cdp: CdpClient
    private let relayQueue = DispatchQueue(label: "ChromeMultiManager.InputSync.SystemRelay")
    private let metricsQueue = DispatchQueue(label: "ChromeMultiManager.InputSync.SystemMetrics")
    private let stateLock = NSLock()
    private let displayHeight: Double

    private var eventTap: CFMachPort?
    private var runLoop: CFRunLoop?
    private var running = false
    private var masterFrame: ManagedWindowFrame?
    private var masterPID: Int?
    private var frontPID: Int?
    private var masterContentFrame: ManagedWindowFrame?
    private var masterPageLikelyFocused = false
    private var targetPIDs: [Int: Int] = [:]
    private var targetFrames: [Int: ManagedWindowFrame] = [:]
    private var addressBarCache: [Int: AXUIElement] = [:]
    private var lastMoveAt = Date.distantPast
    private var lastMoveRatio: (Double, Double)?
    private var dispatchedEventCount = 0

    init(master: ChromeProfile, targets: [ChromeProfile], cdp: CdpClient, pidResolver: @escaping @Sendable (Int) -> Int?) {
        self.master = master
        self.targets = targets
        self.cdp = cdp
        self.pidResolver = pidResolver
        self.displayHeight = CGDisplayBounds(CGMainDisplayID()).height
    }

    var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return running
    }

    func start() throws {
        stateLock.lock()
        running = true
        stateLock.unlock()

        startMetricsLoop()

        let ready = DispatchSemaphore(value: 0)
        let started = LockedValue(false)
        Thread.detachNewThread { [weak self] in
            guard let self else {
                ready.signal()
                return
            }
            let userInfo = Unmanaged.passUnretained(self).toOpaque()
            guard let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .listenOnly,
                eventsOfInterest: self.eventMask(),
                callback: Self.eventCallback,
                userInfo: userInfo
            ) else {
                ready.signal()
                return
            }
            self.stateLock.lock()
            self.eventTap = tap
            self.runLoop = CFRunLoopGetCurrent()
            self.stateLock.unlock()

            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            started.set(true)
            ready.signal()
            CFRunLoopRun()
        }

        _ = ready.wait(timeout: .now() + 3)
        if !started.value {
            stop()
            throw MacInputSyncError.eventTapDenied
        }
        AppLogger.info("input sync started mode=system master=\(master.id) targets=\(targets.map(\.id).map(String.init).joined(separator: ","))")
    }

    func stop() {
        stateLock.lock()
        running = false
        let loop = runLoop
        let tap = eventTap
        runLoop = nil
        eventTap = nil
        stateLock.unlock()

        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let loop {
            CFRunLoopStop(loop)
        }
        AppLogger.info("input sync stopped mode=system master=\(master.id)")
    }

    private func eventMask() -> CGEventMask {
        let types: [CGEventType] = [
            .leftMouseDown,
            .leftMouseUp,
            .rightMouseDown,
            .rightMouseUp,
            .otherMouseDown,
            .otherMouseUp,
            .mouseMoved,
            .leftMouseDragged,
            .rightMouseDragged,
            .otherMouseDragged,
            .keyDown,
            .keyUp,
            .flagsChanged,
            .scrollWheel
        ]
        return types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }
    }

    private static let eventCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else {
            return Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.eventSourceUserData) == relayedEventMarker {
            return Unmanaged.passUnretained(event)
        }
        let synchronizer = Unmanaged<SystemInputSynchronizer>.fromOpaque(userInfo).takeUnretainedValue()
        synchronizer.capture(type: type, event: event)
        return Unmanaged.passUnretained(event)
    }

    private func startMetricsLoop() {
        metricsQueue.async { [weak self] in
            guard let self else { return }
            var lastViewportRefresh = Date.distantPast
            var cachedMasterContentFrame: ManagedWindowFrame?
            while self.isRunning {
                let masterPID = self.pidResolver(self.master.debugPort)
                let frontPID = NSWorkspace.shared.frontmostApplication.map { Int($0.processIdentifier) }
                let masterFrame = masterPID.flatMap { self.windowFrame(pid: $0) }
                if Date().timeIntervalSince(lastViewportRefresh) > 0.5 {
                    cachedMasterContentFrame = self.cdp.viewportMetrics(port: self.master.debugPort).map {
                        ManagedWindowFrame(x: $0.left, y: $0.top, width: $0.width, height: $0.height)
                    }
                    lastViewportRefresh = Date()
                }
                var refreshedFrames: [Int: ManagedWindowFrame] = [:]
                var refreshedPIDs: [Int: Int] = [:]
                for target in self.targets {
                    guard let pid = self.pidResolver(target.debugPort),
                          let frame = self.windowFrame(pid: pid) else {
                        continue
                    }
                    refreshedPIDs[target.debugPort] = pid
                    refreshedFrames[target.debugPort] = frame
                }

                self.stateLock.lock()
                self.masterPID = masterPID
                self.frontPID = frontPID
                self.masterFrame = masterFrame
                self.masterContentFrame = cachedMasterContentFrame
                self.targetPIDs = refreshedPIDs
                self.targetFrames = refreshedFrames
                self.stateLock.unlock()

                Thread.sleep(forTimeInterval: 0.12)
            }
        }
    }

    private func capture(type: CGEventType, event: CGEvent) {
        switch type {
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp, .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel:
            captureMouse(type: type, event: event)
        case .keyDown, .keyUp, .flagsChanged:
            captureKey(event: event)
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            stateLock.lock()
            let tap = eventTap
            stateLock.unlock()
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
        default:
            break
        }
    }

    private func captureMouse(type: CGEventType, event: CGEvent) {
        stateLock.lock()
        let frame = masterFrame
        let contentFrame = masterContentFrame
        stateLock.unlock()
        guard let frame,
              let normalized = frame.normalizedPoint(event.location, displayHeight: displayHeight),
              let copiedEvent = event.copy() else {
            return
        }
        let isInsideContent = contentFrame?.normalizedPoint(event.location, displayHeight: displayHeight) != nil
        if type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown {
            stateLock.lock()
            masterPageLikelyFocused = isInsideContent
            stateLock.unlock()
        }
        if isInsideContent {
            return
        }

        if type == .mouseMoved || type == .leftMouseDragged || type == .rightMouseDragged || type == .otherMouseDragged {
            let now = Date()
            if let lastMoveRatio,
               now.timeIntervalSince(lastMoveAt) < 0.016,
               abs(normalized.ratioX - lastMoveRatio.0) < 0.004,
               abs(normalized.ratioY - lastMoveRatio.1) < 0.004 {
                return
            }
            lastMoveAt = now
            lastMoveRatio = (normalized.ratioX, normalized.ratioY)
        }

        enqueue(.mouse(
            event: EventBox(copiedEvent),
            ratioX: normalized.ratioX,
            ratioY: normalized.ratioY,
            flipForPosting: normalized.flipped
        ))
    }

    private func captureKey(event: CGEvent) {
        stateLock.lock()
        let frontPID = frontPID
        let masterPID = masterPID
        let pageLikelyFocused = masterPageLikelyFocused
        stateLock.unlock()
        guard let frontPID,
              let masterPID,
              frontPID == masterPID else {
            return
        }
        scheduleAddressBarMirror(after: event)
        guard !pageLikelyFocused,
              let copiedEvent = event.copy() else {
            return
        }
        enqueue(.key(event: EventBox(copiedEvent)))
    }

    private func enqueue(_ event: SystemInputEvent) {
        relayQueue.async { [weak self] in
            self?.dispatch(event)
        }
    }

    private func dispatch(_ event: SystemInputEvent) {
        for target in targets {
            let port = target.debugPort
            stateLock.lock()
            let targetPID = targetPIDs[port] ?? pidResolver(port)
            let targetFrame = targetFrames[port]
            stateLock.unlock()

            switch event {
            case let .mouse(eventBox, ratioX, ratioY, flipForPosting):
                guard let targetPID,
                      let targetFrame,
                      let copiedEvent = eventBox.event.copy() else {
                    continue
                }
                copiedEvent.setIntegerValueField(.eventSourceUserData, value: Self.relayedEventMarker)
                copiedEvent.location = targetFrame.point(
                    ratioX: ratioX,
                    ratioY: ratioY,
                    displayHeight: displayHeight,
                    flipForPosting: flipForPosting
                )
                copiedEvent.postToPid(pid_t(targetPID))
            case let .key(eventBox):
                guard let targetPID,
                      let copiedEvent = eventBox.event.copy() else {
                    continue
                }
                copiedEvent.setIntegerValueField(.eventSourceUserData, value: Self.relayedEventMarker)
                copiedEvent.postToPid(pid_t(targetPID))
            }
        }

        dispatchedEventCount += 1
        if dispatchedEventCount % 50 == 0 {
            AppLogger.info("input sync dispatched mode=system events=\(dispatchedEventCount)")
        }
    }

    private func scheduleAddressBarMirror(after event: CGEvent) {
        let shouldNavigate = event.type == .keyDown
            && event.getIntegerValueField(.keyboardEventKeycode) == 36
        relayQueue.asyncAfter(deadline: .now() + 0.04) { [weak self] in
            self?.mirrorAddressBarIfNeeded(navigate: shouldNavigate)
        }
    }

    private func mirrorAddressBarIfNeeded(navigate: Bool) {
        stateLock.lock()
        let masterPID = masterPID
        let frontPID = frontPID
        let targetPIDs = targetPIDs
        stateLock.unlock()

        guard let masterPID,
              frontPID == masterPID,
              let value = focusedAddressBarValue(pid: masterPID) else {
            return
        }

        for (_, targetPID) in targetPIDs {
            setAddressBarValue(pid: targetPID, value: value)
        }

        guard navigate,
              let url = navigationURL(fromAddressText: value) else {
            return
        }
        for port in targetPIDs.keys {
            _ = cdp.navigate(port: port, url: url)
        }
    }

    private func focusedAddressBarValue(pid: Int) -> String? {
        let app = AXUIElementCreateApplication(pid_t(pid))
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &raw) == .success,
              let element = raw else {
            return nil
        }
        let focused = element as! AXUIElement
        guard isAddressBar(focused) else { return nil }
        return axString(focused, kAXValueAttribute as CFString) ?? ""
    }

    private func setAddressBarValue(pid: Int, value: String) {
        guard let element = addressBarElement(pid: pid) else { return }
        let result = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFTypeRef)
        if result != .success {
            addressBarCache[pid] = nil
            AppLogger.info("input sync address mirror skipped pid=\(pid) result=\(result.rawValue)")
        }
    }

    private func addressBarElement(pid: Int) -> AXUIElement? {
        if let cached = addressBarCache[pid], isAddressBar(cached) {
            return cached
        }
        let app = AXUIElementCreateApplication(pid_t(pid))
        let found = findAddressBar(in: app, depth: 0)
        addressBarCache[pid] = found
        return found
    }

    private func findAddressBar(in element: AXUIElement, depth: Int) -> AXUIElement? {
        guard depth < 10 else { return nil }
        if isAddressBar(element) {
            return element
        }
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &raw) == .success,
              let children = raw as? [AXUIElement] else {
            return nil
        }
        for child in children.prefix(80) {
            if let found = findAddressBar(in: child, depth: depth + 1) {
                return found
            }
        }
        return nil
    }

    private func isAddressBar(_ element: AXUIElement) -> Bool {
        guard axString(element, kAXRoleAttribute as CFString) == kAXTextFieldRole as String else {
            return false
        }
        let text = [
            axString(element, kAXDescriptionAttribute as CFString),
            axString(element, kAXTitleAttribute as CFString),
            axString(element, kAXHelpAttribute as CFString)
        ]
        .compactMap { $0 }
        .joined(separator: " ")
        .lowercased()
        return text.contains("地址")
            || text.contains("address")
            || text.contains("search bar")
            || text.contains("omnibox")
    }

    private func axString(_ element: AXUIElement, _ attribute: CFString) -> String? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &raw) == .success else { return nil }
        return raw as? String
    }

    private func navigationURL(fromAddressText text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lowercased = trimmed.lowercased()
        if lowercased.hasPrefix("http://")
            || lowercased.hasPrefix("https://")
            || lowercased.hasPrefix("about:")
            || lowercased.hasPrefix("chrome://")
            || lowercased.hasPrefix("file://") {
            return trimmed
        }
        if !trimmed.contains(" "),
           trimmed.contains(".") {
            return "https://\(trimmed)"
        }
        let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+="))
        let query = trimmed.addingPercentEncoding(withAllowedCharacters: allowed) ?? trimmed
        return "https://www.google.com/search?q=\(query)"
    }

    private func windowFrame(pid: Int) -> ManagedWindowFrame? {
        guard let rawWindows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }
        return rawWindows.compactMap { window -> ManagedWindowFrame? in
            guard (window[kCGWindowOwnerPID as String] as? Int) == pid,
                  (window[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let x = bounds["X"] as? Double,
                  let y = bounds["Y"] as? Double,
                  let width = bounds["Width"] as? Double,
                  let height = bounds["Height"] as? Double,
                  width > 120,
                  height > 80 else {
                return nil
            }
            return ManagedWindowFrame(x: x, y: y, width: width, height: height)
        }
        .max { $0.area < $1.area }
    }
}

final class MacInputSynchronizer: @unchecked Sendable {
    private static let bindingName = "__cmmInputSync"

    private let master: ChromeProfile
    private let targets: [ChromeProfile]
    private let cdp = CdpClient()
    private let pidResolver: @Sendable (Int) -> Int?
    private let relayQueue = DispatchQueue(label: "ChromeMultiManager.InputSync.CDP")
    private let stateLock = NSLock()

    private var running = false
    private var masterConnection: CdpEventConnection?
    private var targetConnections: [Int: CdpEventConnection] = [:]
    private var targetSizes: [Int: CdpViewportSize] = [:]
    private var lastSizeRefresh = Date.distantPast
    private var lastNavigationURL = ""
    private var bridgeReconnectScheduled = false
    private var bridgeGeneration = 0
    private var lastMasterMessageAt = Date()
    private var pendingMouseMove: CdpSyncEvent?
    private var pendingMouseMoveScheduled = false
    private var pendingWheel: CdpSyncEvent?
    private var pendingWheelScheduled = false
    private var dispatchedEventCount = 0
    private var systemSynchronizer: SystemInputSynchronizer?
    private(set) var mode: InputSyncMode = .page
    private(set) var limitedByMissingSystemPermissions = false

    init(master: ChromeProfile, targets: [ChromeProfile], pidResolver: @escaping @Sendable (Int) -> Int?) {
        self.master = master
        self.targets = targets
        self.pidResolver = pidResolver
    }

    var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return running
    }

    var modeTitle: String {
        if limitedByMissingSystemPermissions {
            return "\(mode.title)（仅网页内容）"
        }
        return mode.title
    }

    static func systemPermissionStatus() -> InputSyncPermissionStatus {
        InputSyncPermissionStatus(
            canListenToInput: CGPreflightListenEventAccess(),
            canPostEvents: CGPreflightPostEventAccess()
        )
    }

    @discardableResult
    static func requestSystemPermissions() -> InputSyncPermissionStatus {
        if !CGPreflightListenEventAccess() {
            _ = CGRequestListenEventAccess()
        }
        if !CGPreflightPostEventAccess() {
            _ = CGRequestPostEventAccess()
        }
        return systemPermissionStatus()
    }

    func start(requestSystemPermissions: Bool = true, preferSystemMode: Bool = true) throws {
        guard pidResolver(master.debugPort) != nil else {
            throw MacInputSyncError.noMasterProcess
        }

        let permissionStatus = requestSystemPermissions
            ? Self.requestSystemPermissions()
            : Self.systemPermissionStatus()
        if preferSystemMode, tryStartSystemSynchronizer() {
            return
        }

        AppLogger.info("input sync falling back to page mode listen=\(permissionStatus.canListenToInput) post=\(permissionStatus.canPostEvents)")

        stateLock.lock()
        running = true
        mode = .page
        limitedByMissingSystemPermissions = true
        stateLock.unlock()

        try setupCdpBridge()
        AppLogger.info("input sync started mode=cdp master=\(master.id) targets=\(targets.map(\.id).map(String.init).joined(separator: ","))")
    }

    private func tryStartSystemSynchronizer() -> Bool {
        let synchronizer = SystemInputSynchronizer(master: master, targets: targets, cdp: cdp, pidResolver: pidResolver)
        stateLock.lock()
        running = true
        mode = .system
        limitedByMissingSystemPermissions = false
        systemSynchronizer = synchronizer
        stateLock.unlock()

        do {
            try synchronizer.start()
            try setupCdpBridge()
            AppLogger.info("input sync page bridge started mode=system master=\(master.id)")
            return true
        } catch {
            stateLock.lock()
            running = false
            systemSynchronizer = nil
            stateLock.unlock()
            closeCdpBridge()
            synchronizer.stop()
            AppLogger.info("input sync system mode unavailable error=\(error.localizedDescription)")
            return false
        }
    }

    private func setupCdpBridge() throws {
        guard cdp.page(port: master.debugPort) != nil else {
            throw MacInputSyncError.pageUnavailable
        }

        stateLock.lock()
        bridgeGeneration += 1
        bridgeReconnectScheduled = false
        lastMasterMessageAt = Date()
        let generation = bridgeGeneration
        stateLock.unlock()

        relayQueue.sync {
            closeCdpBridgeLocked()
            for target in targets where pidResolver(target.debugPort) != nil {
                let connection = CdpEventConnection(port: target.debugPort, cdp: cdp)
                targetConnections[target.debugPort] = connection
                targetSizes[target.debugPort] = cdp.viewportSize(port: target.debugPort)
                connection.send(method: "Runtime.evaluate", params: [
                    "expression": Self.cleanupCursorScript,
                    "awaitPromise": false
                ])
            }
            let masterConnection = CdpEventConnection(
                port: master.debugPort,
                cdp: cdp,
                onMessage: { [weak self] message in
                    self?.handleMasterMessage(message)
                },
                onDisconnect: { [weak self] in
                    self?.scheduleCdpBridgeReconnect(reason: "master websocket disconnected")
                }
            )
            self.masterConnection = masterConnection
            masterConnection.send(method: "Runtime.enable", params: [:])
            masterConnection.send(method: "Page.enable", params: [:])
            masterConnection.send(method: "Runtime.addBinding", params: ["name": Self.bindingName])
            masterConnection.send(method: "Page.addScriptToEvaluateOnNewDocument", params: ["source": Self.captureScript])
            masterConnection.send(method: "Runtime.evaluate", params: [
                "expression": Self.cleanupCursorScript + "\n" + Self.captureScript,
                "awaitPromise": false
            ])
        }
        startBridgeWatchdog(generation: generation)
    }

    private func closeCdpBridge() {
        relayQueue.sync {
            closeCdpBridgeLocked()
        }
    }

    private func closeCdpBridgeLocked() {
        masterConnection?.close()
        masterConnection = nil
        for connection in targetConnections.values {
            connection.close()
        }
        targetConnections.removeAll()
        targetSizes.removeAll()
        pendingMouseMove = nil
        pendingWheel = nil
        pendingMouseMoveScheduled = false
        pendingWheelScheduled = false
    }

    func stop() {
        stateLock.lock()
        let systemSynchronizer = systemSynchronizer
        self.systemSynchronizer = nil
        running = false
        bridgeReconnectScheduled = false
        stateLock.unlock()
        if let systemSynchronizer {
            systemSynchronizer.stop()
        }
        closeCdpBridge()
        AppLogger.info("input sync stopped master=\(master.id)")
    }

    private func handleMasterMessage(_ message: [String: Any]) {
        guard isRunning,
              let method = message["method"] as? String,
              let params = message["params"] as? [String: Any] else {
            return
        }

        if method == "Runtime.bindingCalled",
           params["name"] as? String == Self.bindingName,
           let payload = params["payload"] as? String,
           let data = payload.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            markMasterMessageReceived()
            if let event = parseEvent(object) {
                enqueue(event)
            }
            return
        }

        if method == "Page.frameNavigated",
           let frame = params["frame"] as? [String: Any],
           frame["parentId"] == nil,
           let url = frame["url"] as? String,
           shouldMirrorNavigation(url) {
            enqueue(.navigate(url))
        }
    }

    private func markMasterMessageReceived() {
        stateLock.lock()
        lastMasterMessageAt = Date()
        stateLock.unlock()
    }

    private func scheduleCdpBridgeReconnect(reason: String) {
        stateLock.lock()
        guard running, !bridgeReconnectScheduled else {
            stateLock.unlock()
            return
        }
        bridgeReconnectScheduled = true
        stateLock.unlock()

        AppLogger.info("input sync bridge reconnect scheduled reason=\(reason)")
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            let shouldReconnect = self.running
            self.bridgeReconnectScheduled = false
            self.stateLock.unlock()
            guard shouldReconnect else { return }
            do {
                try self.setupCdpBridge()
                AppLogger.info("input sync bridge reconnected master=\(self.master.id)")
            } catch {
                AppLogger.info("input sync bridge reconnect failed error=\(error.localizedDescription)")
                self.scheduleCdpBridgeReconnect(reason: "retry after reconnect failure")
            }
        }
    }

    private func startBridgeWatchdog(generation: Int) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 12) { [weak self] in
            self?.checkBridgeWatchdog(generation: generation)
        }
    }

    private func checkBridgeWatchdog(generation: Int) {
        stateLock.lock()
        let shouldCheck = running && bridgeGeneration == generation
        let idleTime = Date().timeIntervalSince(lastMasterMessageAt)
        stateLock.unlock()
        guard shouldCheck else { return }
        if idleTime > 14 {
            scheduleCdpBridgeReconnect(reason: "master heartbeat timeout")
            return
        }
        startBridgeWatchdog(generation: generation)
    }

    private func parseEvent(_ object: [String: Any]) -> CdpSyncEvent? {
        guard let kind = object["kind"] as? String else { return nil }
        switch kind {
        case "mouse":
            guard let type = object["type"] as? String else { return nil }
            return .mouse(
                type: type,
                ratioX: number(object["rx"]),
                ratioY: number(object["ry"]),
                button: object["button"] as? String ?? "none",
                buttons: int(object["buttons"]),
                clickCount: max(1, int(object["clickCount"])),
                deltaX: number(object["deltaX"]),
                deltaY: number(object["deltaY"]),
                modifiers: int(object["modifiers"])
            )
        case "text":
            let text = object["text"] as? String ?? ""
            return text.isEmpty ? nil : .text(text)
        case "key":
            guard let type = object["type"] as? String,
                  let key = object["key"] as? String,
                  let code = object["code"] as? String else {
                return nil
            }
            return .key(
                type: type,
                key: key,
                code: code,
                windowsVK: int(object["windowsVK"]),
                modifiers: int(object["modifiers"]),
                autoRepeat: bool(object["autoRepeat"])
            )
        default:
            return nil
        }
    }

    private func enqueue(_ event: CdpSyncEvent) {
        relayQueue.async { [weak self] in
            self?.enqueueLocked(event)
        }
    }

    private func enqueueLocked(_ event: CdpSyncEvent) {
        switch event {
        case let .mouse(type, _, _, _, buttons, _, _, _, _) where type == "mouseMoved" && buttons == 0:
            pendingMouseMove = event
            if !pendingMouseMoveScheduled {
                pendingMouseMoveScheduled = true
                relayQueue.asyncAfter(deadline: .now() + 0.012) { [weak self] in
                    self?.flushPendingMouseMoveLocked()
                }
            }
        case .mouse(let type, let ratioX, let ratioY, let button, let buttons, let clickCount, let deltaX, let deltaY, let modifiers) where type == "mouseWheel":
            if case .mouse(_, _, _, _, _, _, let oldDeltaX, let oldDeltaY, _) = pendingWheel {
                pendingWheel = .mouse(
                    type: type,
                    ratioX: ratioX,
                    ratioY: ratioY,
                    button: button,
                    buttons: buttons,
                    clickCount: clickCount,
                    deltaX: oldDeltaX + deltaX,
                    deltaY: oldDeltaY + deltaY,
                    modifiers: modifiers
                )
            } else {
                pendingWheel = event
            }
            if !pendingWheelScheduled {
                pendingWheelScheduled = true
                relayQueue.asyncAfter(deadline: .now() + 0.025) { [weak self] in
                    self?.flushPendingWheelLocked()
                }
            }
        case let .mouse(type, _, _, _, _, _, _, _, _) where type == "mousePressed":
            flushPendingMouseMoveLocked()
            pendingWheel = nil
            pendingWheelScheduled = false
            dispatch(event)
        default:
            dispatch(event)
        }
    }

    private func flushPendingMouseMoveLocked() {
        pendingMouseMoveScheduled = false
        guard let event = pendingMouseMove else { return }
        pendingMouseMove = nil
        dispatch(event)
    }

    private func flushPendingWheelLocked() {
        pendingWheelScheduled = false
        guard let event = pendingWheel else { return }
        pendingWheel = nil
        dispatch(event)
    }

    private func dispatch(_ event: CdpSyncEvent) {
        refreshTargetSizesIfNeeded()
        for target in targets where pidResolver(target.debugPort) != nil {
            let connection = connection(for: target.debugPort)
            switch event {
            case let .mouse(type, ratioX, ratioY, button, buttons, clickCount, deltaX, deltaY, modifiers):
                let size = targetSizes[target.debugPort] ?? CdpViewportSize(width: 1280, height: 800)
                let x = max(0, min(size.width - 1, ratioX * size.width))
                let y = max(0, min(size.height - 1, ratioY * size.height))
                if type == "mousePressed" {
                    connection.send(method: "Input.dispatchMouseEvent", params: [
                        "type": "mouseMoved",
                        "x": x,
                        "y": y,
                        "button": "none",
                        "buttons": 0,
                        "modifiers": modifiers
                    ])
                }
                var params: [String: Any] = [
                    "type": type,
                    "x": x,
                    "y": y,
                    "modifiers": modifiers
                ]
                if type == "mouseWheel" {
                    params["deltaX"] = deltaX
                    params["deltaY"] = deltaY
                } else if type == "mouseMoved" {
                    params["button"] = button
                    params["buttons"] = buttons
                } else {
                    params["button"] = button
                    params["buttons"] = buttons
                    params["clickCount"] = clickCount
                }
                connection.send(method: "Input.dispatchMouseEvent", params: params)
            case let .text(text):
                connection.send(method: "Input.insertText", params: ["text": text])
            case let .key(type, key, code, windowsVK, modifiers, autoRepeat):
                connection.send(method: "Input.dispatchKeyEvent", params: [
                    "type": type,
                    "key": key,
                    "code": code,
                    "windowsVirtualKeyCode": windowsVK,
                    "nativeVirtualKeyCode": windowsVK,
                    "modifiers": modifiers,
                    "autoRepeat": autoRepeat
                ])
            case let .navigate(url):
                connection.send(method: "Page.navigate", params: ["url": url])
            }
        }
        dispatchedEventCount += 1
        if dispatchedEventCount <= 10 || dispatchedEventCount % 50 == 0 {
            AppLogger.info("input sync dispatched mode=cdp events=\(dispatchedEventCount)")
        }
    }

    private func shouldMirrorNavigation(_ url: String) -> Bool {
        guard !url.isEmpty,
              url != "about:blank",
              url != lastNavigationURL else {
            return false
        }
        lastNavigationURL = url
        return true
    }

    private func connection(for port: Int) -> CdpEventConnection {
        if let connection = targetConnections[port] {
            return connection
        }
        let created = CdpEventConnection(port: port, cdp: cdp)
        targetConnections[port] = created
        return created
    }

    private func refreshTargetSizesIfNeeded() {
        let now = Date()
        guard now.timeIntervalSince(lastSizeRefresh) > 0.8 else { return }
        for target in targets where pidResolver(target.debugPort) != nil {
            targetSizes[target.debugPort] = cdp.viewportSize(port: target.debugPort)
        }
        lastSizeRefresh = now
    }

    private func number(_ value: Any?) -> Double {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) ?? 0 }
        return 0
    }

    private func int(_ value: Any?) -> Int {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) ?? 0 }
        return 0
    }

    private func bool(_ value: Any?) -> Bool {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        return false
    }

    private static let cleanupCursorScript = """
    (function(){
      clearTimeout(window.__cmmSyncCursorTimer);
      clearTimeout(window.__cmmInputSyncWheelTimer);
      clearInterval(window.__cmmInputSyncHeartbeat);
      const handlers = window.__cmmInputSyncHandlers;
      if (handlers) {
        document.removeEventListener('mousedown', handlers.sendMouse, true);
        document.removeEventListener('mouseup', handlers.sendMouse, true);
        document.removeEventListener('mousemove', handlers.sendMouse, true);
        document.removeEventListener('wheel', handlers.sendMouse, true);
        document.removeEventListener('keydown', handlers.sendKey, true);
        document.removeEventListener('keyup', handlers.sendKey, true);
        document.removeEventListener('beforeinput', handlers.sendBeforeInput, true);
      }
      delete window.__cmmInputSyncHandlers;
      delete window.__cmmInputSyncInstalled;
      delete window.__cmmInputSyncHeartbeat;
      delete window.__cmmInputSyncWheelTimer;
      const cursor = document.getElementById('__cmm_sync_cursor');
      if (cursor) cursor.remove();
    })();
    """

    private static let captureScript = """
    (function(){
      const binding = '__cmmInputSync';
      const oldHandlers = window.__cmmInputSyncHandlers;
      if (oldHandlers) {
        document.removeEventListener('mousedown', oldHandlers.sendMouse, true);
        document.removeEventListener('mouseup', oldHandlers.sendMouse, true);
        document.removeEventListener('mousemove', oldHandlers.sendMouse, true);
        document.removeEventListener('wheel', oldHandlers.sendMouse, true);
        document.removeEventListener('keydown', oldHandlers.sendKey, true);
        document.removeEventListener('keyup', oldHandlers.sendKey, true);
        document.removeEventListener('beforeinput', oldHandlers.sendBeforeInput, true);
      }
      clearInterval(window.__cmmInputSyncHeartbeat);
      clearTimeout(window.__cmmInputSyncWheelTimer);
      if (typeof window[binding] !== 'function') return;
      window.__cmmInputSyncInstalled = true;
      let seq = 0;
      let lastMoveAt = 0;
      let wheelState = { payload: null, suppressUntil: 0 };
      function clamp01(value){ return Math.max(0, Math.min(1, value)); }
      function modifiers(e){
        let m = 0;
        if (e.altKey) m |= 1;
        if (e.ctrlKey) m |= 2;
        if (e.metaKey) m |= 4;
        if (e.shiftKey) m |= 8;
        return m;
      }
      function send(payload){
        try {
          payload.seq = ++seq;
          payload.href = location.href;
          payload.vw = Math.max(1, window.innerWidth || document.documentElement.clientWidth || 1);
          payload.vh = Math.max(1, window.innerHeight || document.documentElement.clientHeight || 1);
          window[binding](JSON.stringify(payload));
        } catch (_) {}
      }
      function mouseButton(e){
        if (e.button === 0) return 'left';
        if (e.button === 1) return 'middle';
        if (e.button === 2) return 'right';
        return 'none';
      }
      function mouseType(type){
        if (type === 'mousedown') return 'mousePressed';
        if (type === 'mouseup') return 'mouseReleased';
        if (type === 'wheel') return 'mouseWheel';
        return 'mouseMoved';
      }
      function viewport(){
        return {
          width: Math.max(1, window.innerWidth || document.documentElement.clientWidth || 1),
          height: Math.max(1, window.innerHeight || document.documentElement.clientHeight || 1)
        };
      }
      function flushWheel(){
        window.__cmmInputSyncWheelTimer = 0;
        if (!wheelState.payload) return;
        const payload = wheelState.payload;
        wheelState.payload = null;
        send(payload);
      }
      function queueWheel(e){
        const now = performance.now();
        if (now < wheelState.suppressUntil) return;
        const size = viewport();
        const payload = {
          kind: 'mouse',
          type: 'mouseWheel',
          rx: clamp01(e.clientX / size.width),
          ry: clamp01(e.clientY / size.height),
          button: 'none',
          buttons: 0,
          clickCount: e.detail || 1,
          deltaX: e.deltaX || 0,
          deltaY: e.deltaY || 0,
          modifiers: modifiers(e)
        };
        if (wheelState.payload) {
          wheelState.payload.rx = payload.rx;
          wheelState.payload.ry = payload.ry;
          wheelState.payload.deltaX += payload.deltaX;
          wheelState.payload.deltaY += payload.deltaY;
          wheelState.payload.modifiers = payload.modifiers;
        } else {
          wheelState.payload = payload;
        }
        if (!window.__cmmInputSyncWheelTimer) {
          window.__cmmInputSyncWheelTimer = setTimeout(flushWheel, 25);
        }
      }
      function sendMouse(e){
        if (e.type === 'wheel') {
          queueWheel(e);
          return;
        }
        if (e.type === 'mousemove') {
          const now = performance.now();
          if (now - lastMoveAt < (e.buttons ? 12 : 20)) return;
          lastMoveAt = now;
          if (!e.buttons) {
            wheelState.suppressUntil = now + 120;
            wheelState.payload = null;
            clearTimeout(window.__cmmInputSyncWheelTimer);
            window.__cmmInputSyncWheelTimer = 0;
          }
        }
        const size = viewport();
        send({
          kind: 'mouse',
          type: mouseType(e.type),
          rx: clamp01(e.clientX / size.width),
          ry: clamp01(e.clientY / size.height),
          button: e.type === 'mousemove' ? 'none' : mouseButton(e),
          buttons: e.type === 'mouseup' ? 0 : (e.buttons || 0),
          clickCount: e.detail || 1,
          deltaX: 0,
          deltaY: 0,
          modifiers: modifiers(e)
        });
      }
      function sendKey(e){
        if (e.isComposing || e.key === 'Process') return;
        const printable = e.key && e.key.length === 1 && !e.metaKey && !e.ctrlKey;
        if (printable) return;
        send({
          kind: 'key',
          type: e.type === 'keyup' ? 'keyUp' : 'keyDown',
          key: e.key || '',
          code: e.code || '',
          windowsVK: e.keyCode || e.which || 0,
          modifiers: modifiers(e),
          autoRepeat: !!e.repeat
        });
      }
      function sendBeforeInput(e){
        if (typeof e.data === 'string' && e.data.length > 0 && /^insert/.test(e.inputType || '')) {
          send({ kind: 'text', text: e.data });
          return;
        }
        const keyMap = {
          deleteContentBackward: ['keyDown', 'Backspace', 'Backspace', 8],
          deleteContentForward: ['keyDown', 'Delete', 'Delete', 46],
          insertLineBreak: ['keyDown', 'Enter', 'Enter', 13],
          insertParagraph: ['keyDown', 'Enter', 'Enter', 13]
        };
        const mapped = keyMap[e.inputType || ''];
        if (mapped) {
          send({ kind: 'key', type: mapped[0], key: mapped[1], code: mapped[2], windowsVK: mapped[3], modifiers: 0, autoRepeat: false });
          send({ kind: 'key', type: 'keyUp', key: mapped[1], code: mapped[2], windowsVK: mapped[3], modifiers: 0, autoRepeat: false });
        }
      }
      const handlers = { sendMouse, sendKey, sendBeforeInput };
      window.__cmmInputSyncHandlers = handlers;
      document.addEventListener('mousedown', handlers.sendMouse, true);
      document.addEventListener('mouseup', handlers.sendMouse, true);
      document.addEventListener('mousemove', handlers.sendMouse, true);
      document.addEventListener('wheel', handlers.sendMouse, true);
      document.addEventListener('keydown', handlers.sendKey, true);
      document.addEventListener('keyup', handlers.sendKey, true);
      document.addEventListener('beforeinput', handlers.sendBeforeInput, true);
      window.__cmmInputSyncHeartbeat = setInterval(function(){
        send({ kind: 'heartbeat' });
      }, 5000);
      send({ kind: 'ready' });
    })();
    """
}
