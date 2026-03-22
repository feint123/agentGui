import Foundation

struct SessionWorkspacePresentation: Equatable {
    let title: String
    let subtitle: String
    let kindLabel: String
    let representedURL: URL?
    let isMissing: Bool
}

struct SessionWorkspacePresentationFactory {
    func build(session: Session?, globalWorkingDirectory: String) -> SessionWorkspacePresentation {
        let sessionDirectory = session?.workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let globalDirectory = globalWorkingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)

        if !sessionDirectory.isEmpty {
            let url = URL(fileURLWithPath: sessionDirectory).standardizedFileURL
            return SessionWorkspacePresentation(
                title: url.lastPathComponent,
                subtitle: url.path,
                kindLabel: "会话级",
                representedURL: url,
                isMissing: false
            )
        }

        if !globalDirectory.isEmpty {
            let url = URL(fileURLWithPath: globalDirectory).standardizedFileURL
            return SessionWorkspacePresentation(
                title: url.lastPathComponent,
                subtitle: url.path,
                kindLabel: "全局",
                representedURL: url,
                isMissing: false
            )
        }

        return SessionWorkspacePresentation(
            title: "未设置工作区",
            subtitle: "为当前会话选择工作目录后，可在这里看到对应标识。",
            kindLabel: "未设置",
            representedURL: nil,
            isMissing: true
        )
    }
}