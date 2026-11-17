import Foundation
import NetworkExtension
import WireGuardKit

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private let queue = DispatchQueue(label: "netpivot.lifecycle")
    private let api = API()
    private var maintenance: Task<Void, Never>?
    private var expiry: DispatchWorkItem?
    private var generation = UUID()
    private lazy var adapter = WireGuardAdapter(with: self) { _, _ in }

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        queue.async {
            do {
                guard let settings = self.protocolConfiguration as? NETunnelProviderProtocol,
                      let id = settings.providerConfiguration?["network"] as? String,
                      TunnelSnapshot.isID(id) else { throw NetPivotError("找不到网络配置。") }
                let snapshot = try Vault.loadSnapshot(id)
                try snapshot.validate(for: id)
                let tunnel = try self.configuration(snapshot)
                let attempt = UUID()
                self.generation = attempt
                self.adapter.start(tunnelConfiguration: tunnel) { error in
                    self.queue.async {
                        guard self.generation == attempt else {
                            completionHandler(CancellationError())
                            return
                        }
                        if let error { completionHandler(error); return }
                        self.schedule(snapshot, attempt: attempt)
                        self.maintain(snapshot, attempt: attempt)
                        completionHandler(nil)
                    }
                }
            } catch { completionHandler(error) }
        }
    }

    private func configuration(_ snapshot: TunnelSnapshot) throws -> TunnelConfiguration {
        guard let privateKey = PrivateKey(base64Key: try Vault.tunnelKey(snapshot.networkId).base64EncodedString()),
              let publicKey = PublicKey(base64Key: snapshot.publicKey),
              let address = IPAddressRange(from: snapshot.address),
              let endpoint = Endpoint(from: snapshot.endpoint) else {
            throw NetPivotError("无法识别隧道密钥或地址。")
        }
        let routes = snapshot.routes.compactMap(IPAddressRange.init(from:))
        guard routes.count == snapshot.routes.count else { throw NetPivotError("无法识别网络路由。") }
        var local = InterfaceConfiguration(privateKey: privateKey)
        local.addresses = [address]
        local.mtu = UInt16(snapshot.mtu)
        var gateway = PeerConfiguration(publicKey: publicKey)
        gateway.endpoint = endpoint
        gateway.allowedIPs = routes
        gateway.persistentKeepAlive = 25
        return TunnelConfiguration(name: "NetPivot", interface: local, peers: [gateway])
    }

    private func schedule(_ config: TunnelSnapshot, attempt: UUID) {
        expiry?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, generation == attempt else { return }
            cancelTunnelWithError(NetPivotError("连接许可已过期，请重新连接。"))
        }
        expiry = work
        queue.asyncAfter(deadline: .now() + max(0, config.leaseExpiresAt.timeIntervalSinceNow), execute: work)
    }

    private func maintain(_ initial: TunnelSnapshot, attempt: UUID) {
        maintenance = Task { [weak self] in
            guard let self else { return }
            var config = initial
            var delay = 55.0
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(min(delay, max(1, config.leaseExpiresAt.timeIntervalSinceNow - 5))))
                    try await api.discard("POST", "/v1/leases/\(config.leaseId)/renew")
                    let next = try await api.readyConfig(config.networkId, lease: config.leaseId)
                    try next.validate(for: config.networkId, prior: config)
                    try Task.checkCancellation()
                    queue.async { [weak self] in
                        guard let self, generation == attempt else { return }
                        try? Vault.saveSnapshot(next)
                        schedule(next, attempt: attempt)
                    }
                    config = next
                    delay = next.leaseExpiresAt.timeIntervalSinceNow > 240 ? 60 : 8
                } catch is CancellationError {
                    return
                } catch let error as NetPivotError where ["LEASE_REVOKED", "LEASE_EXPIRED", "NETWORK_UNAVAILABLE", "CLIENT_ERROR"].contains(error.code) {
                    queue.async { [weak self] in
                        guard let self, generation == attempt else { return }
                        cancelTunnelWithError(error)
                    }
                    return
                } catch {
                    delay = min(15, max(2, delay / 2))
                }
            }
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        queue.async {
            self.generation = UUID()
            self.expiry?.cancel()
            self.maintenance?.cancel()
            self.maintenance = nil
            self.adapter.stop { _ in completionHandler() }
        }
    }
}
