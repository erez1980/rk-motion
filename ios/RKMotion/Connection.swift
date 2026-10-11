import Foundation
import Security
import CryptoKit

struct Connection: Codable {
    var address: URL
    var fingerprint: String
    var token: String

    static func pairingLink(_ value: String) throws -> (Connection, String) {
        guard let parts = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              parts.scheme == "https", let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.path == "/" || parts.path.isEmpty,
              let fragment = parts.fragment,
              let query = URLComponents(string: "https://pair.invalid/?" + fragment)?.queryItems,
              let code = query.first(where: {$0.name == "pair"})?.value,
              let pin = query.first(where: {$0.name == "fingerprint"})?.value,
              pin.count == 64, pin.allSatisfy({$0.isHexDigit}), !code.isEmpty else {
            throw AppError(message: "Scan or paste the complete private pairing link shown on the Mac.")
        }
        var base = parts; base.fragment = nil; base.query = nil; base.path = ""
        guard let address = base.url else {throw AppError(message: "Invalid Mac address.")}
        return (Connection(address: address, fingerprint: pin.lowercased(), token: ""), code)
    }
    func url(_ path: String) throws -> URL {
        guard path.hasPrefix("/api/"), !path.contains(".."), let result = URL(string: path, relativeTo: address)?.absoluteURL,
              result.host == address.host, result.port == address.port, result.scheme == "https" else {
            throw AppError(message: "Invalid server resource.")
        }
        return result
    }
    func request(_ path: String, method: String = "GET") throws -> URLRequest {
        var request = URLRequest(url: try url(path)); request.httpMethod = method
        if !token.isEmpty {request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")}
        return request
    }
}

enum Credentials {
    static let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.rkmotion.companion", kSecAttrAccount as String: "mac-pairing"]
    static func load() -> Connection? {
        var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else {return nil}
        return try? JSONDecoder().decode(Connection.self, from: data)
    }
    static func save(_ connection: Connection) throws {
        let data = try JSONEncoder().encode(connection)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var q = query; q[kSecValueData as String] = data
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else {throw AppError(message: "Could not store pairing securely.")}
        } else if status != errSecSuccess {throw AppError(message: "Could not update pairing securely.")}
    }
    static func clear() {SecItemDelete(query as CFDictionary)}
}

class PinnedDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    var connection: Connection?
    init(connection: Connection? = nil) { self.connection = connection; super.init() }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let expected = connection ?? Credentials.load(), challenge.protectionSpace.host == expected.address.host,
              let trust = challenge.protectionSpace.serverTrust,
              let certificates = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = certificates.first else {
            completionHandler(.cancelAuthenticationChallenge, nil); return
        }
        let data = SecCertificateCopyData(leaf) as Data
        let pin = SHA256.hash(data: data).map {String(format: "%02x", $0)}.joined()
        SecTrustSetAnchorCertificates(trust, [leaf] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, expected.address.host! as CFString))
        guard pin == expected.fingerprint, SecTrustEvaluateWithError(trust, nil) else {
            completionHandler(.cancelAuthenticationChallenge, nil); return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // The local API has no redirect routes. Reject rather than forwarding
        // credentials or accepting a different server in a background task.
        completionHandler(nil)
    }
}

final class APIClient {
    let connection: Connection
    private let delegate: PinnedDelegate
    private let session: URLSession
    init(_ connection: Connection) {
        self.connection = connection; delegate = PinnedDelegate(connection: connection)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 120
        configuration.httpCookieStorage = nil
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }
    deinit {session.invalidateAndCancel()}
    func call<T: Decodable>(_ path: String, method: String = "GET", body: [String: Any]? = nil,
                            headers: [String: String] = [:]) async throws -> T {
        var request = try connection.request(path, method: method)
        if let body {request.httpBody = try JSONSerialization.data(withJSONObject: body); request.setValue("application/json", forHTTPHeaderField: "Content-Type")}
        headers.forEach {request.setValue($0.value, forHTTPHeaderField: $0.key)}
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let detail = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            throw AppError(message: detail?["error"] as? String ?? "The Mac request failed. Reconnect and try again.")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
