import Foundation
import Network

/// Plain TCP connection to the PC server. Works over Wi-Fi (host = PC's LAN IP)
/// or over USB (host = "127.0.0.1", port forwarded through iproxy - see
/// docs/usb-tunnel.md). The app doesn't need to know which one is active.
final class TCPClient {
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "phonevr.tcp")

    var onData: ((Data) -> Void)?
    var onStateChange: ((NWConnection.State) -> Void)?

    func connect(host: String, port: UInt16) {
        let params = NWParameters.tcp
        if let tcpOptions = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            _ = tcpOptions // keep default; low-latency handled by disabling Nagle below
        }
        let conn = NWConnection(host: NWEndpoint.Host(host),
                                 port: NWEndpoint.Port(rawValue: port)!,
                                 using: params)
        connection = conn
        conn.stateUpdateHandler = { [weak self] state in
            self?.onStateChange?(state)
        }
        conn.start(queue: queue)
        receiveLoop()
    }

    private func receiveLoop() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if let data = data, !data.isEmpty {
                self.onData?(data)
            }
            if error == nil && !isComplete {
                self.receiveLoop()
            }
        }
    }

    func send(_ data: Data) {
        connection?.send(content: data, completion: .contentProcessed { _ in })
    }

    func disconnect() {
        connection?.cancel()
        connection = nil
    }
}
