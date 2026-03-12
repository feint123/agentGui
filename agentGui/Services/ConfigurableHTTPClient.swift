import Foundation
import SwiftAnthropic

#if !os(Linux)

final class ConfigurableHTTPClient: HTTPClient {
    private static let fallbackURL = URL(string: "https://api.anthropic.com")!

    private let settings: AppSettings
    private let requestTimeout: TimeInterval
    private let resourceTimeout: TimeInterval

    init(
        settings: AppSettings,
        requestTimeout: TimeInterval = 300,
        resourceTimeout: TimeInterval = 600
    ) {
        self.settings = settings
        self.requestTimeout = requestTimeout
        self.resourceTimeout = resourceTimeout
    }

    func data(for request: HTTPRequest) async throws -> (Data, HTTPResponse) {
        try await makeAdapter(for: request).data(for: request)
    }

    func bytes(for request: HTTPRequest) async throws -> (HTTPByteStream, HTTPResponse) {
        try await makeAdapter(for: request).bytes(for: request)
    }

    private func makeAdapter(for request: HTTPRequest) -> URLSessionHTTPClientAdapter {
        URLSessionHTTPClientAdapter(urlSession: makeSession(for: request))
    }

    private func makeSession(for request: HTTPRequest) -> URLSession {
        let requestURL = reflectedURL(from: request) ?? Self.fallbackURL
        return ProxyURLSessionFactory.makeSession(
            for: requestURL,
            proxyConfiguration: settings.proxyConfiguration,
            requestTimeout: requestTimeout,
            resourceTimeout: resourceTimeout
        )
    }

    private func reflectedURL(from request: HTTPRequest) -> URL? {
        // SwiftAnthropic exposes HTTPRequest publicly but keeps its stored properties internal.
        // We only need the URL to choose the correct session configuration.
        Mirror(reflecting: request).children.first { $0.label == "url" }?.value as? URL
    }
}

#endif