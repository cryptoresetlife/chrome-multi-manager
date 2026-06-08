import Foundation
import Network

struct AuthProxy: Sendable {
    let host: String
    let port: UInt16
    let username: String
    let password: String
}

final class LocalAuthProxy: @unchecked Sendable {
    let localPort: UInt16
    let upstream: AuthProxy
    private var listener: NWListener?
    private let queue: DispatchQueue

    init(localPort: UInt16, upstream: AuthProxy) {
        self.localPort = localPort
        self.upstream = upstream
        self.queue = DispatchQueue(label: "ChromeMultiManager.LocalAuthProxy.\(localPort)")
    }

    func start() throws {
        let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: localPort)!)
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(client: connection)
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handle(client: NWConnection) {
        client.start(queue: queue)
        readHeader(from: client, buffer: Data())
    }

    private func readHeader(from client: NWConnection, buffer: Data) {
        client.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if error != nil || isComplete {
                client.cancel()
                return
            }
            var next = buffer
            if let data {
                next.append(data)
            }
            if let range = next.range(of: Data("\r\n\r\n".utf8)) {
                let headerEnd = range.upperBound
                let header = next.prefix(headerEnd)
                let rest = next.suffix(from: headerEnd)
                self.connectUpstream(client: client, header: Data(header), rest: Data(rest))
            } else if next.count > 65_536 {
                client.cancel()
            } else {
                self.readHeader(from: client, buffer: next)
            }
        }
    }

    private func connectUpstream(client: NWConnection, header: Data, rest: Data) {
        let upstreamConnection = NWConnection(
            host: NWEndpoint.Host(upstream.host),
            port: NWEndpoint.Port(rawValue: upstream.port)!,
            using: .tcp
        )
        upstreamConnection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .ready = state {
                var firstPacket = self.headerWithAuth(header)
                firstPacket.append(rest)
                upstreamConnection.send(content: firstPacket, completion: .contentProcessed { _ in
                    self.pipe(from: client, to: upstreamConnection)
                    self.pipe(from: upstreamConnection, to: client)
                })
            } else if case .failed = state {
                client.cancel()
                upstreamConnection.cancel()
            }
        }
        upstreamConnection.start(queue: queue)
    }

    private func pipe(from source: NWConnection, to target: NWConnection) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if error != nil || isComplete {
                source.cancel()
                target.cancel()
                return
            }
            guard let data, !data.isEmpty else {
                self.pipe(from: source, to: target)
                return
            }
            target.send(content: data, completion: .contentProcessed { _ in
                self.pipe(from: source, to: target)
            })
        }
    }

    private func headerWithAuth(_ header: Data) -> Data {
        let token = "\(upstream.username):\(upstream.password)"
            .data(using: .utf8)!
            .base64EncodedString()
        let text = String(data: header, encoding: .isoLatin1) ?? String(decoding: header, as: UTF8.self)
        var lines = text.components(separatedBy: "\r\n")
        if !lines.contains(where: { $0.lowercased().hasPrefix("proxy-authorization:") }) {
            lines.insert("Proxy-Authorization: Basic \(token)", at: min(1, lines.count))
        }
        if !lines.contains(where: { $0.lowercased().hasPrefix("proxy-connection:") }) {
            lines.insert("Proxy-Connection: Keep-Alive", at: min(1, lines.count))
        }
        return (lines.joined(separator: "\r\n")).data(using: .isoLatin1) ?? header
    }
}
