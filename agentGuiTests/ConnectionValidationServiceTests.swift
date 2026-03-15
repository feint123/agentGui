import Foundation
import Testing
@testable import agentGui

@MainActor
struct ConnectionValidationServiceTests {

    @Test func validateFailsWhenAPIKeyIsMissing() async {
        let settings = AppSettings.testFixture(apiKey: "")
        let service = ConnectionValidationService(probe: { _ in true })

        let result = await service.validate(settings: settings)

        #expect(result.status == .failed)
        #expect(result.messages.contains(where: { $0.contains("API Key") }))
    }

    @Test func validateFailsWhenBaseURLIsInvalid() async {
        let settings = AppSettings.testFixture(apiKey: "sk-ant-demo")
        settings.baseURL = "not a url"
        let service = ConnectionValidationService(probe: { _ in true })

        let result = await service.validate(settings: settings)

        #expect(result.status == .failed)
        #expect(result.messages.contains(where: { $0.contains("Base URL") }))
    }

    @Test func validateFailsWhenProxyIsEnabledButInvalid() async {
        let settings = AppSettings.testFixture(apiKey: "sk-ant-demo")
        settings.enableNetworkProxy = true
        settings.networkProxyURL = "bad proxy"
        let service = ConnectionValidationService(probe: { _ in true })

        let result = await service.validate(settings: settings)

        #expect(result.status == .failed)
        #expect(result.messages.contains(where: { $0.contains("代理") }))
    }

    @Test func validateSucceedsWhenLocalChecksPassAndProbeReturnsTrue() async {
        let settings = AppSettings.testFixture(apiKey: "sk-ant-demo")
        let service = ConnectionValidationService(probe: { _ in true })

        let result = await service.validate(settings: settings)

        #expect(result.status == .passed)
        #expect(result.messages.contains(where: { $0.contains("连接配置有效") }))
    }
}