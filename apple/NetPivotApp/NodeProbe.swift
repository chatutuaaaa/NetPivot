import Foundation
import Network

// Each measurement sends a fresh nonce over the tunnel and checks the echo.
final class NodeProbe: @unchecked Sendable {
    private let queue = DispatchQueue(label: "netpivot.probe")
    private let connection = NWConnection(host: "10.203.0.1", port: 41820, using: .udp)
    private let payload = Data("NPT1".utf8) + withUnsafeBytes(of: UUID().uuid) { Data($0) }
    private var completion: ((Double?) -> Void)?
    private var started = DispatchTime.now()

    static func measure() async -> Double? {
        let probe = NodeProbe()
        return await withCheckedContinuation { continuation in
            probe.queue.async { probe.start { continuation.resume(returning: $0) } }
        }
    }

    private func start(_ callback: @escaping (Double?) -> Void) {
        completion = callback
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                started = .now()
                connection.send(content: payload, completion: .contentProcessed { [weak self] error in
                    guard let self else { return }
                    if error != nil { finish(nil); return }
                    connection.receiveMessage { [weak self] data, _, _, _ in
                        guard let self else { return }
                        let duration = DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds
                        finish(data == payload ? Double(duration) / 1_000_000 : nil)
                    }
                })
            case .failed, .cancelled: finish(nil)
            default: break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + .seconds(2)) { self.finish(nil) }
    }

    private func finish(_ result: Double?) {
        guard let callback = completion else { return }
        completion = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        callback(result)
    }
}
