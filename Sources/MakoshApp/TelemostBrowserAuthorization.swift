import AuthenticationServices
import AppKit
import MakoshTelemost

/// Native presentation only. Callback production is nonisolated; all UI publication hops to main.
@MainActor final class TelemostBrowserAuthorization: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    private weak var window: NSWindow?
    private var continuation: CheckedContinuation<URL, any Error>?
    private var generation = UUID()
    nonisolated static func callback(_ publish: @escaping @MainActor @Sendable (URL?) -> Void) -> ASWebAuthenticationSession.CompletionHandler {
        { url, _ in Task { @MainActor in publish(url) } }
    }
    func authenticate(_ request: TelemostAuthorizationRequest, window: NSWindow) async throws -> URL {
        guard session == nil, request.expectedCallback.absoluteString == "org.makosh.desktop.telemost://oauth/callback" else { throw TelemostFailure.busy }
        let id = UUID(); generation = id; self.window = window
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let session = ASWebAuthenticationSession(url: request.authURL, callbackURLScheme: "org.makosh.desktop.telemost", completionHandler: Self.callback { [weak self] url in
                    guard let self, self.generation == id else { return }
                    guard let url, self.window?.isVisible == true else { self.finish(.failure(CancellationError())); return }
                    self.finish(.success(url))
                })
                self.session = session; session.presentationContextProvider = self; session.prefersEphemeralWebBrowserSession = true
                if !session.start() { finish(.failure(TelemostFailure.invalidConfiguration)) }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.cancel() } }
    }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor { window ?? ASPresentationAnchor() }
    private func finish(_ result: Result<URL, any Error>) {
        let continuation = continuation; self.continuation = nil; session = nil; window = nil; generation = UUID()
        continuation?.resume(with: result)
    }
    func cancel() { session?.cancel(); finish(.failure(CancellationError())) }
}
