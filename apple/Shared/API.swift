import CryptoKit
import Foundation

private final class NoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

actor API {
    private struct Challenge: Decodable { let challenge: String }
    private struct Session: Decodable { let token: String; let deviceId: String }
    private var session: Session?
    private var sessionTime = Date.distantPast
    private let http: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 12
        return URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
    }()

    private func authenticate() async throws -> Session {
        if let session, Date.now.timeIntervalSince(sessionTime) < 13 * 60 { return session }
        let identity = try Vault.identity()
        let nonce: Challenge = try await send("POST", "/v1/auth/challenges",
            body: ["public_key": identity.publicKey.rawRepresentation.base64EncodedString()])
        let signature = try identity.signature(for: Data("NetPivot session v1\n\(nonce.challenge)".utf8))
        let result: Session = try await send("POST", "/v1/sessions", body: [
            "challenge": nonce.challenge, "signature": signature.base64EncodedString(),
            "name": Vault.preferences.string(forKey: "deviceName") ?? ""
        ])
        session = result
        sessionTime = .now
        return result
    }

    func invalidateIdentitySession() { session = nil }
    func deviceID() async throws -> String { try await authenticate().deviceId }

    func request<T: Decodable>(_ method: String = "GET", _ path: String,
                               body: [String: String]? = nil, idempotency: String? = nil) async throws -> T {
        let current = try await authenticate()
        do {
            return try await send(method, path, body: body, token: current.token, idempotency: idempotency)
        } catch let error as NetPivotError where error.code == "AUTH_REQUIRED" {
            if session?.token == current.token { session = nil }
            let next = try await authenticate()
            return try await send(method, path, body: body, token: next.token, idempotency: idempotency)
        }
    }

    func discard(_ method: String, _ path: String, body: [String: String]? = nil) async throws {
        let _: Empty = try await request(method, path, body: body)
    }

    private struct Empty: Decodable {}

    private func send<T: Decodable>(_ method: String, _ path: String, body: [String: String]? = nil,
                                    token: String? = nil, idempotency: String? = nil) async throws -> T {
        guard let origin = Settings.origin, let url = URL(string: path, relativeTo: origin),
              url.host == origin.host else { throw NetPivotError("应用尚未配置服务地址。") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let token { request.setValue("Bearer "+token, forHTTPHeaderField: "Authorization") }
        if let idempotency { request.setValue(idempotency, forHTTPHeaderField: "Idempotency-Key") }
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (bytes, response) = try await http.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode else {
            throw NetPivotError("节点响应无效，请重试。")
        }
        guard (200..<300).contains(status) else {
            if let error = try? apiDecoder().decode(NetPivotError.self, from: bytes) { throw error }
            throw NetPivotError("服务暂时不可用（\(status)）。")
        }
        return try apiDecoder().decode(T.self, from: status == 204 ? Data("{}".utf8) : bytes)
    }

    func readyConfig(_ network: String, lease: String) async throws -> TunnelSnapshot {
        for attempt in 0..<6 {
            do {
                let config: TunnelSnapshot = try await request("GET", "/v1/networks/\(network)/config")
                try config.validate(for: network)
                guard config.leaseId == lease else { throw NetPivotError("连接许可已变更。") }
                return config
            } catch let error as NetPivotError where error.code == "GATEWAY_PENDING" && attempt < 5 {
                try await Task.sleep(for: .milliseconds(550))
            }
        }
        throw NetPivotError("节点尚未就绪。")
    }
}
