import CryptoKit
import Foundation
import NetworkExtension
import SwiftUI

@MainActor
final class NetworkModel: ObservableObject {
    @Published var networks: [VirtualNetwork] = []
    @Published var selected: String?
    @Published var active: String?
    @Published var status: NEVPNStatus = .invalid
    @Published var latency: Double?
    @Published var busy = false
    @Published var error: String?
    @Published var deviceID = ""
    @Published var invitation: Invitation?
    @Published var preview: InvitationPreview?
    @Published var credential = ""

    private struct Lease: Decodable { let leaseId: String }
    private let api = API()
    private var manager: NETunnelProviderManager?
    private var createKey: String?
    private var probeFor: String?
    private var minutesUntilProbe = Date.distantPast

    func refresh() async {
        do {
            if manager == nil {
                manager = try await NETunnelProviderManager.loadAllFromPreferences().first
            }
            readStatus()
            if deviceID.isEmpty { deviceID = try await api.deviceID() }
            let list: [VirtualNetwork] = try await api.request("GET", "/v1/networks")
            networks = list
            if !busy, let selected, !list.contains(where: { $0.id == selected }) { self.selected = nil }
            if let active, status == .connected, probeFor == nil, Date.now >= minutesUntilProbe {
                probeFor = active
                let value = await NodeProbe.measure()
                if self.active == active && status == .connected { latency = value }
                probeFor = nil
                minutesUntilProbe = .now.addingTimeInterval(8)
            }
        } catch is CancellationError {
        } catch {
            if networks.isEmpty && !busy { self.error = error.localizedDescription }
        }
    }

    func readStatus() {
        status = manager?.connection.status ?? .invalid
        switch status {
        case .connected, .connecting, .reasserting, .disconnecting:
            active = (manager?.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration?["network"] as? String
            if status != .connected { latency = nil }
        default:
            active = nil
            latency = nil
        }
    }

    func perform(_ action: () async throws -> Void) async {
        guard !busy else { return }
        busy = true
        error = nil
        defer { busy = false }
        do { try await action() }
        catch is CancellationError {}
        catch { self.error = error.localizedDescription }
    }

    private func show(_ network: VirtualNetwork) {
        if let index = networks.firstIndex(where: { $0.id == network.id }) { networks[index] = network }
        else { networks.insert(network, at: 0) }
        selected = network.id
    }

    func create() async {
        await perform {
            let key = createKey ?? UUID().uuidString
            createKey = key
            let network: VirtualNetwork = try await api.request("POST", "/v1/networks", body: ["name": "朋友的联机网络"], idempotency: key)
            createKey = nil
            show(network)
            try await connectTo(network.id)
        }
    }

    func connect(_ id: String) async {
        await perform { try await connectTo(id) }
    }

    private func connectTo(_ id: String) async throws {
        guard TunnelSnapshot.isID(id) else { throw NetPivotError("网络标识无效。") }
        if manager == nil { manager = try await NETunnelProviderManager.loadAllFromPreferences().first }
        readStatus()
        if active == id && status == .connected { return }
        if active != nil { try await stopCurrent() }
        let key = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Vault.tunnelKey(id))
        let start: Lease = try await api.request("POST", "/v1/networks/\(id)/connect",
            body: ["public_key": key.publicKey.rawRepresentation.base64EncodedString()])
        do {
            let snapshot = try await api.readyConfig(id, lease: start.leaseId)
            try Vault.saveSnapshot(snapshot)
            let tunnelManager = manager ?? NETunnelProviderManager()
            let configuration = NETunnelProviderProtocol()
            configuration.providerBundleIdentifier = Settings.value("NetPivotTunnelID")
            configuration.serverAddress = snapshot.endpoint
            configuration.providerConfiguration = ["network": id]
            configuration.disconnectOnSleep = false
            tunnelManager.protocolConfiguration = configuration
            tunnelManager.localizedDescription = "NetPivot"
            tunnelManager.isEnabled = true
            try await tunnelManager.saveToPreferences()
            try await tunnelManager.loadFromPreferences()
            manager = tunnelManager
            try tunnelManager.connection.startVPNTunnel()
            minutesUntilProbe = .distantPast
            for _ in 0..<24 {
                try await Task.sleep(for: .milliseconds(400))
                readStatus()
                if status == .connected {
                    let value = await NodeProbe.measure()
                    readStatus()
                    if active == id && status == .connected { latency = value }
                    return
                }
                if status == .invalid || status == .disconnected { break }
            }
            tunnelManager.connection.stopVPNTunnel()
            throw NetPivotError("VPN 未能连接，请检查系统权限、网络或其他正在运行的 VPN。")
        } catch {
            let failure = error
            try? await api.discard("DELETE", "/v1/leases/\(start.leaseId)")
            readStatus()
            throw failure
        }
    }

    private func stopCurrent() async throws {
        guard let manager else { return }
        let previous = active.flatMap { try? Vault.loadSnapshot($0) }
        manager.connection.stopVPNTunnel()
        for _ in 0..<30 {
            readStatus()
            if status == .invalid || status == .disconnected { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        guard status == .invalid || status == .disconnected else {
            throw NetPivotError("系统仍在断开 VPN，请稍后再试。")
        }
        if let previous { try? await api.discard("DELETE", "/v1/leases/\(previous.leaseId)") }
    }

    func disconnect() async { await perform { try await stopCurrent() } }

    func resolve(_ input: String) async {
        await perform {
            let clean = input.trimmingCharacters(in: .whitespacesAndNewlines)
            if let url = URL(string: clean), url.scheme != nil {
                guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                      components.scheme == "https", components.host == Settings.origin?.host,
                      components.user == nil, components.path == "/j",
                      let fragment = components.percentEncodedFragment else {
                    throw NetPivotError("这个链接不是 NetPivot 邀请。")
                }
                var fields = URLComponents()
                fields.percentEncodedQuery = fragment
                guard let token = fields.queryItems?.first(where: { $0.name == "t" })?.value,
                      TunnelSnapshot.isID(token) else { throw NetPivotError("邀请链接不完整。") }
                credential = token
            } else {
                let code = clean.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: " ", with: "").uppercased()
                guard code.utf8.count == 8, code.allSatisfy({ "0123456789ABCDEFGHJKMNPQRSTVWXYZ".contains($0) }) else {
                    throw NetPivotError("请输入 8 位邀请码。")
                }
                credential = code
            }
            preview = try await api.request("POST", "/v1/invitations/resolve", body: ["credential": credential])
        }
    }

    func redeem() async {
        await perform {
            let n: VirtualNetwork = try await api.request("POST", "/v1/invitations/redeem", body: ["credential": credential])
            credential = ""
            preview = nil
            show(n)
            try await connectTo(n.id)
        }
    }

    func invite(_ id: String, rotate: Bool = false) async {
        await perform {
            invitation = try await api.request("POST", "/v1/networks/\(id)/invitations" + (rotate ? "?rotate=1" : ""))
        }
    }

    func revoke(_ id: String) async {
        await perform {
            try await api.discard("DELETE", "/v1/networks/\(id)/invitations")
            invitation = nil
        }
    }

    func memberAction(_ id: String, member: String, transfer: Bool = false) async {
        await perform {
            if transfer {
                let updated: VirtualNetwork = try await api.request("PATCH", "/v1/networks/\(id)/owner",
                    body: ["device_id": member])
                show(updated)
            } else {
                try await api.discard("DELETE", "/v1/networks/\(id)/members/\(member)")
                if member == deviceID {
                    if active == id { try await stopCurrent() }
                    networks.removeAll { $0.id == id }
                    selected = nil
                } else {
                    let updated: VirtualNetwork = try await api.request("GET", "/v1/networks/\(id)")
                    show(updated)
                }
            }
        }
    }

    func disband(_ id: String) async {
        await perform {
            try await api.discard("DELETE", "/v1/networks/\(id)")
            if active == id { try await stopCurrent() }
            networks.removeAll { $0.id == id }
            selected = nil
        }
    }

    func saveName(_ name: String) async {
        await perform {
            Vault.preferences.set(name, forKey: "deviceName")
            await api.invalidateIdentitySession()
            deviceID = try await api.deviceID()
            await refresh()
        }
    }
}
