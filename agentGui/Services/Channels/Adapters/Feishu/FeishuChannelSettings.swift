import Foundation

struct FeishuChannelSettings: Equatable, Sendable {
    private enum Key {
        static let messageFormat = "feishu.messageFormat"
    }

    var messageFormat: FeishuMessageFormat = .text

    init(messageFormat: FeishuMessageFormat = .text) {
        self.messageFormat = messageFormat
    }

    init(binding: ChannelAccountBinding) {
        if let rawValue = binding.stringSetting(forKey: Key.messageFormat),
           let format = FeishuMessageFormat(rawValue: rawValue) {
            self.messageFormat = format
        } else {
            self.messageFormat = .text
        }
    }

    func apply(to binding: ChannelAccountBinding) {
        binding.setStringSetting(messageFormat.rawValue, forKey: Key.messageFormat)
    }
}