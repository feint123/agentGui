//
//  AgentConfigSheet.swift
//  agentGui
//
//  Created by feint on 2026/2/10.
//

import SwiftUI
import UniformTypeIdentifiers

/// Agent 配置表单模式
enum AgentConfigMode {
    case create
    case edit(AgentConfiguration)
}

/// Agent 配置表单视图
struct AgentConfigSheet: View {

    // MARK: - Properties

    let mode: AgentConfigMode
    let onSave: (AgentConfiguration) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var agentType: AgentType
    @State private var connectionType: ConnectionType
    @State private var executablePath: String
    @State private var arguments: String
    @State private var remoteURL: String
    @State private var authToken: String
    @State private var workingDirectory: String
    @State private var autoConnect: Bool
    @State private var showingFilePicker = false

    // 表单验证错误
    @State private var nameError: String?
    @State private var pathError: String?
    @State private var urlError: String?

    // MARK: - Initialization

    init(mode: AgentConfigMode, onSave: @escaping (AgentConfiguration) -> Void) {
        self.mode = mode
        self.onSave = onSave

        switch mode {
        case .create:
            _name = State(initialValue: "")
            _agentType = State(initialValue: .claudeCode)
            _connectionType = State(initialValue: .stdio)
            _executablePath = State(initialValue: "")
            _arguments = State(initialValue: "")
            _remoteURL = State(initialValue: "")
            _authToken = State(initialValue: "")
            _workingDirectory = State(initialValue: FileManager.default.homeDirectoryForCurrentUser.path)
            _autoConnect = State(initialValue: false)
        case .edit(let agent):
            _name = State(initialValue: agent.name)
            _agentType = State(initialValue: agent.agentType)
            _connectionType = State(initialValue: agent.connectionType)
            _executablePath = State(initialValue: agent.executablePath ?? "")
            _arguments = State(initialValue: agent.arguments.joined(separator: " "))
            _remoteURL = State(initialValue: agent.remoteURL ?? "")
            _authToken = State(initialValue: agent.authToken ?? "")
            _workingDirectory = State(initialValue: agent.defaultWorkingDirectory)
            _autoConnect = State(initialValue: agent.autoConnect)
        }
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Form {
                basicInfoSection
                connectionSection
                advancedSection
                autoConnectSection
            }
            .formStyle(.grouped)
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        saveAgent()
                    }
                    .disabled(!isValid)
                }
            }
            .fileImporter(
                isPresented: $showingFilePicker,
                allowedContentTypes: [.item],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first {
                        executablePath = url.path
                    }
                case .failure:
                    break
                }
            }
        }
        .frame(minWidth: 500, minHeight: 400)
    }

    // MARK: - Form Sections

    private var basicInfoSection: some View {
        Section("基本信息") {
            TextField("Agent 名称", text: $name)
                .textFieldStyle(.roundedBorder)

            Picker("Agent 类型", selection: $agentType) {
                ForEach(AgentType.allCases, id: \.self) { type in
                    Text(type.displayName).tag(type)
                }
            }
            .pickerStyle(.menu)
        }
    }

    private var connectionSection: some View {
        Section("连接配置") {
            Picker("连接方式", selection: $connectionType) {
                Text("标准输入/输出").tag(ConnectionType.stdio)
                Text("WebSocket").tag(ConnectionType.websocket)
            }
            .pickerStyle(.segmented)

            if connectionType == .stdio {
                stdioConnectionFields
            } else {
                webSocketConnectionFields
            }
        }
    }

    @ViewBuilder
    private var stdioConnectionFields: some View {
        HStack {
            TextField("可执行文件路径", text: $executablePath)
                .textFieldStyle(.roundedBorder)

            Button("选择") {
                showingFilePicker = true
            }
            .buttonStyle(.bordered)
        }

        if let pathError = pathError {
            Text(pathError)
                .font(.caption)
                .foregroundStyle(.red)
        }

        TextField("命令行参数 (空格分隔)", text: $arguments)
            .textFieldStyle(.roundedBorder)

        TextField("工作目录", text: $workingDirectory)
            .textFieldStyle(.roundedBorder)
    }

    @ViewBuilder
    private var webSocketConnectionFields: some View {
        TextField("WebSocket URL", text: $remoteURL)
            .textFieldStyle(.roundedBorder)

        if let urlError = urlError {
            Text(urlError)
                .font(.caption)
                .foregroundStyle(.red)
        }

        TextField("认证令牌 (可选)", text: $authToken)
            .textFieldStyle(.roundedBorder)
    }

    private var advancedSection: some View {
        Section("高级配置") {
            Text("环境变量")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("在此配置环境变量 (即将推出)")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var autoConnectSection: some View {
        Section {
            Toggle("启动时自动连接", isOn: $autoConnect)

            Text("启用后，应用启动时会自动尝试连接此 Agent")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Computed Properties

    private var title: String {
        switch mode {
        case .create:
            return "添加 Agent"
        case .edit:
            return "编辑 Agent"
        }
    }

    private var isValid: Bool {
        validateName().isValid &&
        validatePath().isValid &&
        validateURL().isValid
    }

    // MARK: - Validation

    private func validateName() -> (isValid: Bool, error: String?) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            nameError = "名称不能为空"
            return (false, nameError)
        }
        nameError = nil
        return (true, nil)
    }

    private func validatePath() -> (isValid: Bool, error: String?) {
        if connectionType == .stdio {
            let trimmed = executablePath.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                pathError = "请指定可执行文件路径"
                return (false, pathError)
            }

            // 检查文件是否存在
            if !FileManager.default.fileExists(atPath: trimmed) {
                pathError = "文件不存在"
                return (false, pathError)
            }
        }
        pathError = nil
        return (true, nil)
    }

    private func validateURL() -> (isValid: Bool, error: String?) {
        if connectionType == .websocket {
            let trimmed = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                urlError = "请指定 WebSocket URL"
                return (false, urlError)
            }

            if URL(string: trimmed) == nil {
                urlError = "URL 格式无效"
                return (false, urlError)
            }
        }
        urlError = nil
        return (true, nil)
    }

    // MARK: - Actions

    private func saveAgent() {
        let agent: AgentConfiguration

        switch mode {
        case .create:
            agent = AgentConfiguration(
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                agentType: agentType,
                connectionType: connectionType,
                executablePath: connectionType == .stdio ? executablePath : nil,
                remoteURL: connectionType == .websocket ? remoteURL : nil,
                authToken: authToken.isEmpty ? nil : authToken,
                defaultWorkingDirectory: workingDirectory.isEmpty ? FileManager.default.homeDirectoryForCurrentUser.path : workingDirectory,
                autoConnect: autoConnect
            )
        case .edit(let existingAgent):
            agent = AgentConfiguration(
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                agentType: agentType,
                connectionType: connectionType,
                executablePath: connectionType == .stdio ? executablePath : nil,
                remoteURL: connectionType == .websocket ? remoteURL : nil,
                authToken: authToken.isEmpty ? nil : authToken,
                defaultWorkingDirectory: workingDirectory.isEmpty ? FileManager.default.homeDirectoryForCurrentUser.path : workingDirectory,
                autoConnect: autoConnect
            )
            // 更新 ID 以保持引用
            agent.id = existingAgent.id
        }

        onSave(agent)
    }

    private func parseArguments(_ input: String) -> [String] {
        // 简单的参数解析
        return input.split(separator: " ").map { String($0) }
    }
}

// MARK: - Preview

#Preview("Create Mode") {
    AgentConfigSheet(mode: .create) { _ in }
        .frame(width: 600, height: 500)
}

#Preview("Edit Mode") {
    let agent = AgentConfiguration(
        name: "Claude Code",
        agentType: .claudeCode,
        connectionType: .stdio
    )
    return AgentConfigSheet(mode: .edit(agent)) { _ in }
        .frame(width: 600, height: 500)
}
