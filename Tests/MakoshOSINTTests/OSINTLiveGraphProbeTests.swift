import Foundation
import MakoshGoogle
import XCTest

@testable import MakoshOSINT

/// Prints the raw graph JSON of the live sketch named by `MAKOSH_OSINT_LIVE_PROBE_SKETCH` through the tunnel.
/// Only on the user's command; the output is the user's own data.
final class OSINTLiveGraphProbeTests: XCTestCase {
    func testPrintLiveGraph() async throws {
        let e = ProcessInfo.processInfo.environment
        guard let host = e["MAKOSH_OSINT_LIVE_HOST"], let sketch = e["MAKOSH_OSINT_LIVE_PROBE_SKETCH"],
            let file = e["MAKOSH_OSINT_LIVE_PASSWORD_FILE"], let login = e["MAKOSH_OSINT_LIVE_LOGIN"],
            let fingerprint = e["MAKOSH_OSINT_LIVE_FINGERPRINT"]
        else { throw XCTSkip("probe runs only on the user's command") }
        let password = try String(contentsOfFile: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let vault = OSINTCredentialVault(access: .system)
        let session = OSINTSSHSession(host: host, port: 22, login: login, password: { password }, expectedFingerprint: fingerprint)
        _ = try await session.connect { _ in false }
        let tunnel = try await session.openTunnel(toPort: 5173)
        let email = e["MAKOSH_OSINT_LIVE_SERVICE_EMAIL"] ?? "makosh-osint@sh-inc.dev"
        let stored = try await vault.servicePassword()
        let service = try XCTUnwrap(stored)
        var tokenRequest = URLRequest(url: tunnel.baseURL.appendingPathComponent("/api/auth/token"))
        tokenRequest.httpMethod = "POST"
        tokenRequest.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        func form(_ value: String) -> String {
            value.addingPercentEncoding(withAllowedCharacters: CharacterSet.alphanumerics.union(.init(charactersIn: "-._~"))) ?? value
        }
        tokenRequest.httpBody = Data("username=\(form(email))&password=\(form(service))".utf8)
        let (tokenData, _) = try await URLSession.shared.data(for: tokenRequest)
        let token = try XCTUnwrap((try JSONSerialization.jsonObject(with: tokenData) as? [String: Any])?["access_token"] as? String)
        let path = e["MAKOSH_OSINT_LIVE_PROBE_PATH"] ?? "/api/sketches/\(sketch)/graph"
        var graph = URLRequest(url: tunnel.baseURL.appendingPathComponent(path))
        graph.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: graph)
        print("PROBE status: \((response as? HTTPURLResponse)?.statusCode ?? 0) bytes: \(data.count)")
        print("PROBE: \(String(decoding: data.prefix(400_000), as: UTF8.self))")
        await session.close()
    }
}
