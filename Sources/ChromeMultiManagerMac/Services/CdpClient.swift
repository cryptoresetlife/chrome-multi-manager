import Foundation

struct DevToolsPage: Decodable {
    let type: String?
    let webSocketDebuggerUrl: String?
}

struct CdpViewportMetrics: Sendable {
    let left: Double
    let top: Double
    let width: Double
    let height: Double
}

struct CdpViewportSize: Sendable {
    let width: Double
    let height: Double
}

struct CdpWindowBounds: Sendable {
    let left: Int
    let top: Int
    let width: Int
    let height: Int
}

final class CdpClient: @unchecked Sendable {
    func navigate(port: Int, url: String) -> Bool {
        send(port: port, method: "Page.navigate", params: ["url": url])
    }

    func evaluate(port: Int, expression: String) -> Bool {
        send(port: port, method: "Runtime.evaluate", params: ["expression": expression])
    }

    func updateBadge(profile: ChromeProfile) -> Bool {
        let configuredIP = proxyHost(profile.proxy)
        let expression = """
        (function(){
          const badgeId = '__chrome_manager_window_badge';
          const windowNo = \(profile.id);
          const profileName = \(jsonLiteral(profile.name));
          const configuredIp = \(jsonLiteral(configuredIP));
          const title = '窗口 #' + windowNo + (profileName ? '  ' + profileName : '');
          function ensureBadge(){
            let el = document.getElementById(badgeId);
            if (!el) {
              el = document.createElement('div');
              el.id = badgeId;
              (document.body || document.documentElement).appendChild(el);
            }
            el.style.cssText = [
              'position:fixed',
              'left:8px',
              'top:8px',
              'z-index:2147483647',
              'padding:5px 8px',
              'border-radius:6px',
              'background:rgba(17,24,39,.88)',
              'color:#fff',
              'border:1px solid rgba(255,255,255,.22)',
              'font:12px/1.35 Arial,Microsoft YaHei,sans-serif',
              'letter-spacing:0',
              'box-shadow:0 4px 14px rgba(0,0,0,.22)',
              'pointer-events:none',
              'white-space:nowrap'
            ].join(';');
            return el;
          }
          function setBadge(ip, source){
            ensureBadge().textContent = title + '  |  ' + source + ': ' + (ip || '未知');
          }
          setBadge(configuredIp || '检测中', configuredIp ? '配置IP' : '出口IP');
          fetch('https://api.ipify.org?format=json', { cache: 'no-store' })
            .then(function(r){ return r.json(); })
            .then(function(data){ if (data && data.ip) setBadge(data.ip, '出口IP'); })
            .catch(function(){ if (!configuredIp) setBadge('', '出口IP'); });
        })();
        """
        return evaluate(port: profile.debugPort, expression: expression)
    }

    func viewportMetrics(port: Int) -> CdpViewportMetrics? {
        let expression = """
        JSON.stringify({
          screenX: window.screenX,
          screenY: window.screenY,
          outerWidth: window.outerWidth,
          outerHeight: window.outerHeight,
          innerWidth: window.innerWidth,
          innerHeight: window.innerHeight
        })
        """
        guard let value = evaluateValue(port: port, expression: expression) as? String,
              let data = value.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let screenX = number(object["screenX"])
        let screenY = number(object["screenY"])
        let outerWidth = number(object["outerWidth"])
        let outerHeight = number(object["outerHeight"])
        let innerWidth = number(object["innerWidth"])
        let innerHeight = number(object["innerHeight"])
        guard innerWidth > 0, innerHeight > 0 else { return nil }
        let leftInset = max(0, (outerWidth - innerWidth) / 2)
        let topInset = max(0, outerHeight - innerHeight)
        return CdpViewportMetrics(
            left: screenX + leftInset,
            top: screenY + topInset,
            width: innerWidth,
            height: innerHeight
        )
    }

    func viewportSize(port: Int) -> CdpViewportSize {
        guard let metrics = viewportMetrics(port: port) else {
            return CdpViewportSize(width: 1280, height: 800)
        }
        return CdpViewportSize(width: max(1, metrics.width), height: max(1, metrics.height))
    }

    func windowBounds(port: Int) -> CdpWindowBounds? {
        guard let response = sendAndReceive(port: port, method: "Browser.getWindowForTarget", params: [:], timeout: 2),
              let result = response["result"] as? [String: Any],
              let bounds = result["bounds"] as? [String: Any] else {
            return nil
        }
        return CdpWindowBounds(
            left: Int(number(bounds["left"])),
            top: Int(number(bounds["top"])),
            width: max(1, Int(number(bounds["width"]))),
            height: max(1, Int(number(bounds["height"])))
        )
    }

    func setWindowBounds(port: Int, left: Int, top: Int, width: Int, height: Int) -> Bool {
        guard let windowID = windowID(port: port) else { return false }
        _ = sendAndReceive(
            port: port,
            method: "Browser.setWindowBounds",
            params: [
                "windowId": windowID,
                "bounds": ["windowState": "normal"]
            ],
            timeout: 1
        )
        return sendAndReceive(
            port: port,
            method: "Browser.setWindowBounds",
            params: [
                "windowId": windowID,
                "bounds": [
                    "left": left,
                    "top": top,
                    "width": width,
                    "height": height
                ]
            ],
            timeout: 2
        ) != nil
    }

    func evaluateValue(port: Int, expression: String) -> Any? {
        let response = sendAndReceive(
            port: port,
            method: "Runtime.evaluate",
            params: [
                "expression": expression,
                "returnByValue": true,
                "awaitPromise": false
            ],
            timeout: 2
        )
        let result = response?["result"] as? [String: Any]
        let nested = result?["result"] as? [String: Any]
        return nested?["value"]
    }

    func page(port: Int) -> DevToolsPage? {
        if let page = listedPage(port: port) {
            return page
        }
        _ = createPage(port: port)
        return listedPage(port: port)
    }

    private func listedPage(port: Int) -> DevToolsPage? {
        guard let url = URL(string: "http://127.0.0.1:\(port)/json/list"),
              let data = try? Data(contentsOf: url),
              let pages = try? JSONDecoder().decode([DevToolsPage].self, from: data) else {
            return nil
        }
        return pages.first { $0.type == "page" && $0.webSocketDebuggerUrl != nil }
    }

    private func createPage(port: Int) -> DevToolsPage? {
        guard let url = URL(string: "http://127.0.0.1:\(port)/json/new?about:blank") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        guard let data = httpData(for: request, timeout: 2) else {
            return nil
        }
        return try? JSONDecoder().decode(DevToolsPage.self, from: data)
    }

    private func httpData(for request: URLRequest, timeout: TimeInterval) -> Data? {
        let semaphore = DispatchSemaphore(value: 0)
        let result = LockedValue<Data?>(nil)
        let task = URLSession.shared.dataTask(with: request) { data, _, _ in
            result.set(data)
            semaphore.signal()
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + timeout)
        task.cancel()
        return result.value
    }

    private func send(port: Int, method: String, params: [String: Any]) -> Bool {
        sendAndReceive(port: port, method: method, params: params, timeout: 3) != nil
    }

    private func windowID(port: Int) -> Int? {
        guard let response = sendAndReceive(port: port, method: "Browser.getWindowForTarget", params: [:], timeout: 2),
              let result = response["result"] as? [String: Any] else {
            return nil
        }
        return int(result["windowId"])
    }

    private func sendAndReceive(port: Int, method: String, params: [String: Any], timeout: TimeInterval) -> [String: Any]? {
        guard let page = page(port: port),
              let socketURLString = page.webSocketDebuggerUrl,
              let socketURL = URL(string: socketURLString) else {
            return nil
        }
        let payload: [String: Any] = [
            "id": Int(Date().timeIntervalSince1970 * 1000) % 1_000_000,
            "method": method,
            "params": params
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: socketURL)
        let semaphore = DispatchSemaphore(value: 0)
        let response = LockedValue<[String: Any]?>(nil)
        task.resume()
        task.send(.string(text)) { error in
            if error != nil {
                semaphore.signal()
                return
            }
            task.receive { result in
                if case .success(let message) = result {
                    switch message {
                    case .string(let string):
                        if let data = string.data(using: .utf8),
                           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                            response.set(object)
                        }
                    case .data(let data):
                        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                            response.set(object)
                        }
                    @unknown default:
                        break
                    }
                }
                semaphore.signal()
            }
        }
        _ = semaphore.wait(timeout: .now() + timeout)
        task.cancel(with: .normalClosure, reason: nil)
        session.invalidateAndCancel()
        return response.value
    }

    private func jsonLiteral(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let raw = String(data: data, encoding: .utf8),
              raw.count >= 2 else {
            return "\"\""
        }
        return String(raw.dropFirst().dropLast())
    }

    private func proxyHost(_ proxy: String) -> String {
        let trimmed = proxy.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let normalized = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
        guard let components = URLComponents(string: normalized) else { return "" }
        return components.host ?? ""
    }

    private func number(_ value: Any?) -> Double {
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        if let string = value as? String {
            return Double(string) ?? 0
        }
        return 0
    }

    private func int(_ value: Any?) -> Int? {
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let string = value as? String {
            return Int(string)
        }
        return nil
    }
}

final class CdpEventConnection: @unchecked Sendable {
    private let port: Int
    private let cdp: CdpClient
    private let onMessage: (([String: Any]) -> Void)?
    private let onDisconnect: (() -> Void)?
    private let session = URLSession(configuration: .ephemeral)
    private let lock = NSLock()
    private var task: URLSessionWebSocketTask?
    private var messageID = 1000
    private var closed = false

    init(port: Int, cdp: CdpClient, onMessage: (([String: Any]) -> Void)? = nil, onDisconnect: (() -> Void)? = nil) {
        self.port = port
        self.cdp = cdp
        self.onMessage = onMessage
        self.onDisconnect = onDisconnect
    }

    func close() {
        lock.lock()
        closed = true
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        lock.unlock()
        session.invalidateAndCancel()
    }

    func send(method: String, params: [String: Any]) {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        messageID += 1
        let payload: [String: Any] = [
            "id": messageID,
            "method": method,
            "params": params
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8),
              let task = ensureTaskLocked() else {
            lock.unlock()
            return
        }
        lock.unlock()
        task.send(.string(text)) { [weak self] error in
            guard error != nil else { return }
            self?.markDisconnected(task)
        }
    }

    private func ensureTaskLocked() -> URLSessionWebSocketTask? {
        if let task, task.state == .running {
            return task
        }
        task = nil
        guard let page = cdp.page(port: port),
              let rawURL = page.webSocketDebuggerUrl,
              let url = URL(string: rawURL) else {
            return nil
        }
        let newTask = session.webSocketTask(with: url)
        task = newTask
        newTask.resume()
        receiveLoop(newTask)
        return newTask
    }

    private func receiveLoop(_ webSocketTask: URLSessionWebSocketTask) {
        webSocketTask.receive { [weak self, weak webSocketTask] result in
            guard let self, let webSocketTask else { return }
            guard case .success(let message) = result else {
                self.markDisconnected(webSocketTask)
                return
            }
            if let object = self.decode(message) {
                self.onMessage?(object)
            }
            self.lock.lock()
            let shouldContinue = !self.closed && self.task === webSocketTask
            self.lock.unlock()
            if shouldContinue {
                self.receiveLoop(webSocketTask)
            }
        }
    }

    private func markDisconnected(_ webSocketTask: URLSessionWebSocketTask) {
        lock.lock()
        let shouldNotify = !closed && task === webSocketTask
        if shouldNotify {
            task = nil
        }
        lock.unlock()
        if shouldNotify {
            onDisconnect?()
        }
    }

    private func decode(_ message: URLSessionWebSocketTask.Message) -> [String: Any]? {
        switch message {
        case .string(let string):
            guard let data = string.data(using: .utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        case .data(let data):
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        @unknown default:
            return nil
        }
    }
}
