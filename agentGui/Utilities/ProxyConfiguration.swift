//
//  ProxyConfiguration.swift
//  agentGui
//

import Foundation
import CFNetwork

struct ProxyConfiguration: Sendable {
    let isEnabled: Bool
    let proxyURLString: String
    let bypassList: [String]

    var normalizedProxyURL: String? {
        guard isEnabled else { return nil }
        let trimmed = proxyURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, URL(string: trimmed) != nil else { return nil }
        return trimmed
    }

    var url: URL? {
        guard let normalizedProxyURL else { return nil }
        return URL(string: normalizedProxyURL)
    }

    var bashEnvironmentOverrides: [String: String] {
        guard let normalizedProxyURL else { return [:] }

        var env: [String: String] = [
            "HTTP_PROXY": normalizedProxyURL,
            "HTTPS_PROXY": normalizedProxyURL,
            "ALL_PROXY": normalizedProxyURL,
            "http_proxy": normalizedProxyURL,
            "https_proxy": normalizedProxyURL,
            "all_proxy": normalizedProxyURL,
        ]

        if !bypassList.isEmpty {
            let joined = bypassList.joined(separator: ",")
            env["NO_PROXY"] = joined
            env["no_proxy"] = joined
        }
        return env
    }

    func shouldBypassProxy(for url: URL) -> Bool {
        guard let host = url.host?.lowercased(), !bypassList.isEmpty else { return false }

        for rawPattern in bypassList {
            let pattern = rawPattern.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !pattern.isEmpty else { continue }
            if pattern == "*" || pattern == host { return true }

            let normalizedPattern = pattern.hasPrefix(".") ? String(pattern.dropFirst()) : pattern
            if host == normalizedPattern || host.hasSuffix("." + normalizedPattern) {
                return true
            }
        }

        return false
    }

    var connectionProxyDictionary: [AnyHashable: Any]? {
        guard let url, let host = url.host else { return nil }

        let scheme = url.scheme?.lowercased() ?? "http"
        let port = url.port ?? defaultPort(for: scheme)
        var dictionary: [AnyHashable: Any] = [:]

        if scheme.hasPrefix("socks") {
            dictionary[kCFNetworkProxiesSOCKSEnable as String] = 1
            dictionary[kCFNetworkProxiesSOCKSProxy as String] = host
            dictionary[kCFNetworkProxiesSOCKSPort as String] = port
        } else {
            dictionary[kCFNetworkProxiesHTTPEnable as String] = 1
            dictionary[kCFNetworkProxiesHTTPProxy as String] = host
            dictionary[kCFNetworkProxiesHTTPPort as String] = port
            dictionary[kCFNetworkProxiesHTTPSEnable as String] = 1
            dictionary[kCFNetworkProxiesHTTPSProxy as String] = host
            dictionary[kCFNetworkProxiesHTTPSPort as String] = port
        }

        return dictionary
    }

    private func defaultPort(for scheme: String) -> Int {
        switch scheme {
        case "https":
            return 443
        case "socks", "socks5", "socks5h":
            return 1080
        default:
            return 80
        }
    }
}

enum ProxyURLSessionFactory {
    static func makeSession(
        for url: URL,
        proxyConfiguration: ProxyConfiguration,
        requestTimeout: TimeInterval = 300,
        resourceTimeout: TimeInterval = 600
    ) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout

        if proxyConfiguration.normalizedProxyURL != nil,
           !proxyConfiguration.shouldBypassProxy(for: url),
           let proxyDictionary = proxyConfiguration.connectionProxyDictionary {
            configuration.connectionProxyDictionary = proxyDictionary
        }

        return URLSession(configuration: configuration)
    }
}

extension AppSettings {
    var proxyBypassEntries: [String] {
        networkProxyBypassList
            .split { $0 == "," || $0 == "\n" || $0 == " " || $0 == "\t" }
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    var proxyConfiguration: ProxyConfiguration {
        ProxyConfiguration(
            isEnabled: enableNetworkProxy,
            proxyURLString: networkProxyURL,
            bypassList: proxyBypassEntries
        )
    }
}