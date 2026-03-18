import Foundation
import Observation

@MainActor
@Observable
final class FeishuChannelConnectionStatusStore {
    enum Phase: Equatable, Sendable {
        case stopped
        case connecting
        case connected
        case reconnecting
        case failed

        var displayText: String {
            switch self {
            case .stopped:
                return "未启动"
            case .connecting:
                return "连接中"
            case .connected:
                return "已连接"
            case .reconnecting:
                return "重连中"
            case .failed:
                return "连接失败"
            }
        }
    }

    static let shared = FeishuChannelConnectionStatusStore()

    var phase: Phase = .stopped
    var lastErrorMessage: String?
    var connectedURL: URL?
    var serviceID: Int32?
    var negotiatedProtocol: String?
    var lastConnectedAt: Date?
    var lastEventAt: Date?
    var lastCloseCode: Int?
    var lastCloseReason: String?
    var lastHandshakeHTTPStatus: Int?
    var lastHandshakeHeaders: [String: String] = [:]
    var lastHandshakeStatus: Int?
    var lastHandshakeMessage: String?
    var lastHandshakeAuthErrorCode: Int?

    func reportConnecting() {
        phase = .connecting
        lastErrorMessage = nil
        resetConnectionDiagnostics()
        connectedURL = nil
        serviceID = nil
        negotiatedProtocol = nil
    }

    func reportConnected(url: URL, serviceID: Int32, at: Date) {
        phase = .connected
        resetConnectionDiagnostics()
        connectedURL = url
        self.serviceID = serviceID
        lastConnectedAt = at
        lastErrorMessage = nil
    }

    func reportReconnecting(_ errorMessage: String?) {
        phase = .reconnecting
        if let errorMessage, !errorMessage.isEmpty {
            lastErrorMessage = errorMessage
        }
    }

    func reportFailure(_ errorMessage: String) {
        phase = .failed
        lastErrorMessage = errorMessage
    }

    func reportStopped() {
        phase = .stopped
        resetConnectionDiagnostics()
        connectedURL = nil
        serviceID = nil
        negotiatedProtocol = nil
    }

    func reportSocketOpened(protocol negotiatedProtocol: String?) {
        self.negotiatedProtocol = negotiatedProtocol
    }

    func reportSocketClosed(code: Int, reason: String?) {
        lastCloseCode = code
        lastCloseReason = reason
    }

    func reportEventReceived(at: Date) {
        lastEventAt = at
    }

    func reportHandshakeResponse(httpStatusCode: Int, headers: [String: String]) {
        lastHandshakeHTTPStatus = httpStatusCode
        lastHandshakeHeaders = headers
        lastHandshakeStatus = headers["handshake-status"].flatMap(Int.init)
        lastHandshakeMessage = headers["handshake-msg"]
        lastHandshakeAuthErrorCode = headers["handshake-autherrcode"].flatMap(Int.init)
    }

    private func resetConnectionDiagnostics() {
        lastCloseCode = nil
        lastCloseReason = nil
        lastHandshakeHTTPStatus = nil
        lastHandshakeHeaders = [:]
        lastHandshakeStatus = nil
        lastHandshakeMessage = nil
        lastHandshakeAuthErrorCode = nil
    }
}