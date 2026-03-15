import SwiftUI

struct LSPManagementSectionView: View {
    let viewModel: LSPManagementViewModel

    @State private var expandedServiceIDs: Set<String> = []
    @State private var busyServiceID: String?
    @State private var actionError: String?

    var body: some View {
        Section {
            ForEach(viewModel.services) { service in
                VStack(alignment: .leading, spacing: 10) {
                    LSPServiceRowView(
                        service: service,
                        isBusy: busyServiceID == service.id,
                        isExpanded: expandedServiceIDs.contains(service.id),
                        onToggleDetail: {
                            if expandedServiceIDs.contains(service.id) {
                                expandedServiceIDs.remove(service.id)
                            } else {
                                expandedServiceIDs.insert(service.id)
                            }
                        },
                        onAction: { action in
                            Task {
                                busyServiceID = service.id
                                defer { busyServiceID = nil }
                                do {
                                    try await viewModel.perform(action, for: service.id)
                                    actionError = nil
                                } catch {
                                    actionError = error.localizedDescription
                                }
                            }
                        }
                    )

                    if expandedServiceIDs.contains(service.id) {
                        LSPServiceDetailView(service: service)
                    }
                }
                .padding(.vertical, 4)
            }

            if let actionError, !actionError.isEmpty {
                Text(actionError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("LSP 服务")
        } footer: {
            Text("安装、重检、启动和重启等操作都通过统一服务目录完成；高级自定义 profile 仍可继续使用。")
        }
    }
}