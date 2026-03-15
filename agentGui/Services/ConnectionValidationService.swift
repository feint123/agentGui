import Foundation

enum ConnectionValidationStatus: Equatable {
    case passed
    case failed
}

struct ConnectionValidationResult: Equatable {
    let status: ConnectionValidationStatus
    let messages: [String]
}

struct ConnectionValidationService {
    private let probe: (@Sendable (URL) -> Bool)?

    init(probe: (@Sendable (URL) -> Bool)? = nil) {
        self.probe = probe
    }

    func validate(settings: AppSettings) async -> ConnectionValidationResult {
        var failures: [String] = []

        let apiKey = settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if apiKey.isEmpty {
            failures.append("缺少 Anthropic API Key。")
        }

        let trimmedBaseURL = settings.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedBaseURL.isEmpty, !Self.isValidEndpointURLString(trimmedBaseURL) {
            failures.append("Base URL 不是有效的 URL。")
        }

        if settings.enableNetworkProxy,
           !Self.isValidEndpointURLString(settings.networkProxyURL.trimmingCharacters(in: .whitespacesAndNewlines)) {
            failures.append("代理已启用，但代理 URL 无效。")
        }

        guard failures.isEmpty else {
            return ConnectionValidationResult(status: .failed, messages: failures)
        }

        let validationURL = validationTargetURL(for: settings)
        let isReachable: Bool
        if let probe {
            isReachable = probe(validationURL)
        } else {
            isReachable = await Self.probeReachability(url: validationURL, settings: settings)
        }

        guard isReachable else {
            return ConnectionValidationResult(
                status: .failed,
                messages: ["无法连接到 \(validationURL.host ?? validationURL.absoluteString)。请检查 Base URL、网络或代理配置。"]
            )
        }

        return ConnectionValidationResult(
            status: .passed,
            messages: ["连接配置有效，可以继续保存并开始使用。"]
        )
    }

    private func validationTargetURL(for settings: AppSettings) -> URL {
        let trimmedBaseURL = settings.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmedBaseURL), !trimmedBaseURL.isEmpty {
            return url
        }
        return URL(string: "https://api.anthropic.com")!
    }

    private static func isValidEndpointURLString(_ rawValue: String) -> Bool {
        guard let components = URLComponents(string: rawValue),
              let scheme = components.scheme,
              !scheme.isEmpty,
              let host = components.host,
              !host.isEmpty else {
            return false
        }
        return true
    }

    private static func probeReachability(url: URL, settings: AppSettings) async -> Bool {
        let session = ProxyURLSessionFactory.makeSession(
            for: url,
            proxyConfiguration: settings.proxyConfiguration,
            requestTimeout: 5,
            resourceTimeout: 10
        )
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"

        do {
            let (_, response) = try await session.data(for: request)
            return response is HTTPURLResponse
        } catch {
            return false
        }
    }
}