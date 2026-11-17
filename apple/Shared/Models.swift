import Foundation

enum Settings {
    static func value(_ key: String) -> String {
        Bundle.main.object(forInfoDictionaryKey: key) as? String ?? ""
    }

    static var origin: URL? {
        var c = URLComponents()
        c.scheme = "https"
        c.host = value("NetPivotHost")
        return c.host?.isEmpty == false ? c.url : nil
    }
}

struct DeviceMember: Codable, Identifiable, Hashable {
    let deviceId: String
    let name: String
    let address: String
    let online: Bool
    var id: String { deviceId }
}

struct VirtualNetwork: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let ownerDeviceId: String
    let members: [DeviceMember]
}

struct Invitation: Codable {
    let code: String
    let url: URL
    let expiresAt: Date
}

struct InvitationPreview: Codable {
    let name: String
    let inviter: String
    let count: Int
}

struct TunnelSnapshot: Codable {
    let schemaVersion: Int
    let networkId: String
    let revision: UInt64
    let leaseId: String
    let leaseExpiresAt: Date
    let address: String
    let routes: [String]
    let endpoint: String
    let publicKey: String
    let mtu: Int

    func validate(for id: String, prior: TunnelSnapshot? = nil) throws {
        let addressParts = address.split(separator: ".")
        guard schemaVersion == 1, networkId == id, Self.isID(id), Self.isID(leaseId),
              leaseExpiresAt > .now, leaseExpiresAt.timeIntervalSinceNow <= 310,
              mtu == 1280, addressParts.count == 4,
              addressParts[0] == "10", addressParts[1] == "203",
              let subnet = UInt8(addressParts[2]), (1...254).contains(subnet),
              addressParts[3].hasSuffix("/32"),
              let host = UInt8(addressParts[3].dropLast(3)), (10...254).contains(host),
              address == "10.203.\(subnet).\(host)/32",
              Set(routes) == ["10.203.\(subnet).0/24", "10.203.0.1/32"],
              routes.count == 2, let key = Data(base64Encoded: publicKey), key.count == 32,
              key.contains(where: { $0 != 0 }),
              !endpoint.contains(where: { $0.isWhitespace || $0.isNewline }) else {
            throw NetPivotError("连接配置无效，请重新连接。")
        }
        if let prior, leaseId != prior.leaseId || revision < prior.revision ||
            address != prior.address || routes != prior.routes ||
            endpoint != prior.endpoint || publicKey != prior.publicKey {
            throw NetPivotError("连接设置已变更，请重新连接。")
        }
    }

    static func isID(_ value: String) -> Bool {
        value.utf8.count == 32 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }
}

struct NetPivotError: LocalizedError, Decodable {
    let code: String
    let message: String
    let retryable: Bool
    let requestId: String?

    init(_ message: String, code: String = "CLIENT_ERROR") {
        self.message = message
        self.code = code
        retryable = false
        requestId = nil
    }
    var errorDescription: String? { message }
}

func apiDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    decoder.dateDecodingStrategy = .custom { decoder in
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        if let parsed = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value) {
            return parsed
        }
        if let parsed = try? Date.ISO8601FormatStyle().parse(value) { return parsed }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO date")
    }
    return decoder
}
