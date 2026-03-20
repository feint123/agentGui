import Testing
@testable import agentGui

@MainActor
struct ACPPermissionCenterTests {
    @Test func interactiveApprovalQueuesPendingRequestUntilUserSelectsOption() async throws {
        let center = ACPPermissionCenter()
        let policy = ToolAuthorizationPolicy(preset: .actLimited, approvalMode: .alwaysRequireHuman)
        let request = makeRequest(
            options: [
                ACPPermissionOption(meta: nil, kind: .rejectOnce, name: "拒绝一次", optionID: "reject-once"),
                ACPPermissionOption(meta: nil, kind: .allowOnce, name: "允许一次", optionID: "allow-once"),
                ACPPermissionOption(meta: nil, kind: .allowAlways, name: "始终允许", optionID: "allow-always")
            ]
        )

        let task = Task {
            await center.resolve(
                request: request,
                source: ACPPermissionCenter.RequestSource(providerID: .githubCopilotCLI, localSessionID: "local-1"),
                policy: policy
            )
        }

        while center.pendingRequests.isEmpty {
            await Task.yield()
        }

        let pending = try #require(center.pendingRequest(localSessionID: "local-1", toolCallID: "tool-1"))
        #expect(pending.title == "Run tests")
        #expect(pending.reason == "需要执行测试命令")
        #expect(pending.options.map(\.id) == ["reject-once", "allow-once", "allow-always"])

        center.selectOption(requestID: pending.id, optionID: "allow-always")

        let response = try #require(await task.value)
        switch response.outcome {
        case .selected(let outcome):
            #expect(outcome.optionID == "allow-always")
        default:
            Issue.record("Expected selected permission outcome")
        }

        #expect(center.pendingRequests.isEmpty)
    }

    @Test func selectingRejectOptionPreservesOptionSelection() async throws {
        let center = ACPPermissionCenter()
        let policy = ToolAuthorizationPolicy(preset: .actLimited, approvalMode: .alwaysRequireHuman)
        let request = makeRequest(
            options: [
                ACPPermissionOption(meta: nil, kind: .rejectAlways, name: "始终拒绝", optionID: "reject-always"),
                ACPPermissionOption(meta: nil, kind: .allowOnce, name: "允许一次", optionID: "allow-once")
            ]
        )

        let task = Task {
            await center.resolve(
                request: request,
                source: ACPPermissionCenter.RequestSource(providerID: .githubCopilotCLI, localSessionID: "local-1"),
                policy: policy
            )
        }

        while center.pendingRequests.isEmpty {
            await Task.yield()
        }

        let pending = try #require(center.pendingRequests.first)
        center.selectOption(requestID: pending.id, optionID: "reject-always")

        let response = try #require(await task.value)
        switch response.outcome {
        case .selected(let outcome):
            #expect(outcome.optionID == "reject-always")
        default:
            Issue.record("Expected selected reject option outcome")
        }
    }

    @Test func deniedCapabilityCancelsWithoutQueuingApproval() async throws {
        let center = ACPPermissionCenter()
        let policy = ToolAuthorizationPolicy(preset: .observeOnly, approvalMode: .alwaysRequireHuman)
        let response = try #require(
            await center.resolve(
                request: makeRequest(),
                source: ACPPermissionCenter.RequestSource(providerID: .githubCopilotCLI, localSessionID: "local-1"),
                policy: policy
            )
        )

        switch response.outcome {
        case .cancelled:
            break
        default:
            Issue.record("Expected permission request to be cancelled when capability is denied")
        }

        #expect(center.pendingRequests.isEmpty)
    }

    @Test func aliasToolKindsQueueApprovalWhenPolicyAllowsCapability() async throws {
        let center = ACPPermissionCenter()
        let policy = ToolAuthorizationPolicy(preset: .observeOnly, approvalMode: .alwaysRequireHuman)
        let request = makeRequest(kind: "read_file", title: "Read file")

        let task = Task {
            await center.resolve(
                request: request,
                source: ACPPermissionCenter.RequestSource(providerID: .githubCopilotCLI, localSessionID: "local-1"),
                policy: policy
            )
        }

        while center.pendingRequests.isEmpty {
            await Task.yield()
        }

        let pending = try #require(center.pendingRequests.first)
        #expect(pending.toolKind == .read)
        #expect(pending.title == "Read file")

        center.cancel(requestID: pending.id)
        let response = try #require(await task.value)
        switch response.outcome {
        case .cancelled:
            break
        default:
            Issue.record("Expected alias read tool to remain pending until user resolves it")
        }
    }

    @Test func aliasMutationToolKindsRespectDeniedCapabilities() async throws {
        let center = ACPPermissionCenter()
        let policy = ToolAuthorizationPolicy(preset: .observeOnly, approvalMode: .alwaysRequireHuman)
        let response = try #require(
            await center.resolve(
                request: makeRequest(kind: "str_replace", title: "Edit file"),
                source: ACPPermissionCenter.RequestSource(providerID: .githubCopilotCLI, localSessionID: "local-1"),
                policy: policy
            )
        )

        switch response.outcome {
        case .cancelled:
            break
        default:
            Issue.record("Expected alias edit tool to be denied under observe-only policy")
        }

        #expect(center.pendingRequests.isEmpty)
    }

    @Test func cancellingSessionResolvesPendingRequests() async throws {
        let center = ACPPermissionCenter()
        let policy = ToolAuthorizationPolicy(preset: .actLimited, approvalMode: .alwaysRequireHuman)

        let task = Task {
            await center.resolve(
                request: makeRequest(),
                source: ACPPermissionCenter.RequestSource(providerID: .githubCopilotCLI, localSessionID: "local-1"),
                policy: policy
            )
        }

        while center.pendingRequests.isEmpty {
            await Task.yield()
        }

        center.cancelRequests(for: "local-1")

        let response = try #require(await task.value)
        switch response.outcome {
        case .cancelled:
            break
        default:
            Issue.record("Expected pending request to be cancelled when the session is reset")
        }

        #expect(center.pendingRequests.isEmpty)
    }

    private func makeRequest(
        options: [ACPPermissionOption]? = nil,
        kind: String = "execute",
        title: String = "Run tests"
    ) -> ACPRequestPermissionRequest {
        ACPRequestPermissionRequest(
            meta: nil,
            options: options ?? [
                ACPPermissionOption(meta: nil, kind: .allowOnce, name: "允许一次", optionID: "allow-once")
            ],
            sessionID: "remote-1",
            toolCall: ACPToolCallUpdatePayload(
                meta: nil,
                content: .object(["reason": .string("需要执行测试命令")]),
                kind: kind,
                locations: nil,
                rawInput: nil,
                rawOutput: nil,
                status: "pending",
                title: title,
                toolCallID: "tool-1"
            )
        )
    }
}