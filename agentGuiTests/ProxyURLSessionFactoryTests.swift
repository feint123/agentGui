import CFNetwork
import Foundation
import Testing
@testable import agentGui

struct ProxyURLSessionFactoryTests {

    @Test func makeSessionAppliesTimeoutsWithoutProxy() {
        let session = ProxyURLSessionFactory.makeSession(
            for: URL(string: "https://api.anthropic.com/v1/messages")!,
            proxyConfiguration: ProxyConfiguration(
                isEnabled: false,
                proxyURLString: "",
                bypassList: []
            ),
            requestTimeout: 123,
            resourceTimeout: 456
        )

        #expect(session.configuration.timeoutIntervalForRequest == 123)
        #expect(session.configuration.timeoutIntervalForResource == 456)
        #expect(session.configuration.connectionProxyDictionary == nil)
    }

    @Test func makeSessionAppliesProxyDictionaryWhenProxyEnabled() {
        let session = ProxyURLSessionFactory.makeSession(
            for: URL(string: "https://api.anthropic.com/v1/messages")!,
            proxyConfiguration: ProxyConfiguration(
                isEnabled: true,
                proxyURLString: "http://127.0.0.1:7890",
                bypassList: []
            )
        )

        let proxyDictionary = try? #require(session.configuration.connectionProxyDictionary)
        #expect(proxyDictionary?[kCFNetworkProxiesHTTPEnable as String] as? Int == 1)
        #expect(proxyDictionary?[kCFNetworkProxiesHTTPProxy as String] as? String == "127.0.0.1")
        #expect(proxyDictionary?[kCFNetworkProxiesHTTPPort as String] as? Int == 7890)
    }

    @Test func makeSessionSkipsProxyForBypassedHost() {
        let session = ProxyURLSessionFactory.makeSession(
            for: URL(string: "https://api.anthropic.com/v1/messages")!,
            proxyConfiguration: ProxyConfiguration(
                isEnabled: true,
                proxyURLString: "http://127.0.0.1:7890",
                bypassList: ["anthropic.com"]
            )
        )

        #expect(session.configuration.connectionProxyDictionary == nil)
    }
}