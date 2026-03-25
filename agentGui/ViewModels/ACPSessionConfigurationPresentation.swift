import Foundation

struct ACPSessionConfigControl: Equatable {
    let id: String
    let title: String
    let options: [ExecutionOptionItem]
    let selectedValue: String
}

struct ACPSessionConfigurationPresentation: Equatable {
    let providerID: ConversationExecutionProviderID
    let providerDisplayName: String
    let modeOptions: [ExecutionOptionItem]
    let selectedModeID: String?
    let modelConfig: ACPSessionConfigControl?
    let approvalsConfig: ACPSessionConfigControl?

    var hasControls: Bool {
        !modeOptions.isEmpty || modelConfig != nil || approvalsConfig != nil
    }
}

enum ACPSessionConfigurationPresentationBuilder {
    static func make(
        providerID: ConversationExecutionProviderID,
        snapshot: ACPExternalAgentSessionConfigurationSnapshot
    ) -> ACPSessionConfigurationPresentation {
        ACPSessionConfigurationPresentation(
            providerID: providerID,
            providerDisplayName: providerID.displayName,
            modeOptions: modeOptions(from: snapshot),
            selectedModeID: snapshot.modes?.currentModeID,
            modelConfig: control(from: snapshot.modelConfigOption, fallbackTitle: "模型"),
            approvalsConfig: control(from: snapshot.approvalConfigOption, fallbackTitle: "Approvals")
        )
    }

    private static func modeOptions(from snapshot: ACPExternalAgentSessionConfigurationSnapshot) -> [ExecutionOptionItem] {
        guard let modes = snapshot.modes else { return [] }
        var options = modes.availableModes.map { ExecutionOptionItem(id: $0.id, title: $0.name) }
        if options.contains(where: { $0.id == modes.currentModeID }) == false {
            options.append(ExecutionOptionItem(id: modes.currentModeID, title: modes.currentModeID))
        }
        return options
    }

    private static func control(
        from option: ACPSessionConfigOption?,
        fallbackTitle: String
    ) -> ACPSessionConfigControl? {
        guard let option,
              let id = option.id?.trimmingCharacters(in: .whitespacesAndNewlines),
              !id.isEmpty else {
            return nil
        }

        let executionOptions = option.options.flattenedOptions.map {
            ExecutionOptionItem(id: $0.value, title: $0.name)
        }
        guard executionOptions.isEmpty == false else {
            return nil
        }

        return ACPSessionConfigControl(
            id: id,
            title: title(for: option, fallbackTitle: fallbackTitle),
            options: executionOptions,
            selectedValue: option.currentValue
        )
    }

    private static func title(for option: ACPSessionConfigOption, fallbackTitle: String) -> String {
        switch option.category {
        case .model:
            return "模型"
        default:
            return fallbackTitle
        }
    }
}