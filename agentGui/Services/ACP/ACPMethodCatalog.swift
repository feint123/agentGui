import Foundation

enum ACPMethodCatalog {
    static let protocolVersion = 1

    enum Agent {
        static let authenticate = "authenticate"
        static let initialize = "initialize"
        static let sessionCancel = "session/cancel"
        static let sessionList = "session/list"
        static let sessionLoad = "session/load"
        static let sessionNew = "session/new"
        static let sessionPrompt = "session/prompt"
        static let sessionSetConfigOption = "session/set_config_option"
        static let sessionSetMode = "session/set_mode"
    }

    enum Client {
        static let filesystemReadTextFile = "fs/read_text_file"
        static let filesystemWriteTextFile = "fs/write_text_file"
        static let sessionRequestPermission = "session/request_permission"
        static let sessionUpdate = "session/update"
        static let terminalCreate = "terminal/create"
        static let terminalKill = "terminal/kill"
        static let terminalOutput = "terminal/output"
        static let terminalRelease = "terminal/release"
        static let terminalWaitForExit = "terminal/wait_for_exit"
    }
}