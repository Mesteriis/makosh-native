import Foundation

final class WhatsAppAvatarHTTP: WhatsAppAvatarFetching, @unchecked Sendable {
  private let configuration: URLSessionConfiguration
  init(configuration: URLSessionConfiguration = .ephemeral) {
    let config = configuration.copy() as! URLSessionConfiguration
    config.httpCookieStorage = nil
    config.httpShouldSetCookies = false
    config.urlCredentialStorage = nil
    config.urlCache = nil
    config.requestCachePolicy = .reloadIgnoringLocalCacheData
    self.configuration = config
  }
  static func accepts(_ url: URL) -> Bool {
    guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased(),
      url.user == nil, url.password == nil, url.fragment == nil, url.port == nil || url.port == 443
    else { return false }
    return host == "pps.whatsapp.net" || host.hasSuffix(".pps.whatsapp.net")
  }
  func fetch(_ url: URL, maximumBytes: Int, timeout: TimeInterval) async throws -> Data {
    guard Self.accepts(url), (1...4 * 1024 * 1024).contains(maximumBytes), timeout > 0,
      timeout <= 20
    else {
      throw WhatsAppFailure.invalid
    }
    let config = configuration.copy() as! URLSessionConfiguration
    config.timeoutIntervalForRequest = timeout
    config.timeoutIntervalForResource = timeout
    let session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    var request = URLRequest(
      url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
    request.httpShouldHandleCookies = false
    let (stream, response) = try await session.bytes(for: request)
    guard let response = response as? HTTPURLResponse, response.statusCode == 200,
      response.url == url, response.expectedContentLength <= maximumBytes
    else { throw WhatsAppFailure.invalid }
    var result = Data()
    result.reserveCapacity(min(maximumBytes, 64 * 1024))
    for try await byte in stream {
      try Task.checkCancellation()
      guard result.count < maximumBytes else { throw WhatsAppFailure.invalid }
      result.append(byte)
    }
    return result
  }
  private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
      _ session: URLSession, task: URLSessionTask,
      willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
      completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) { completionHandler(nil) }
  }
}
