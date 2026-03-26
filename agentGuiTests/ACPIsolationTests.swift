import Foundation
import Testing
@testable import agentGui

@MainActor
struct ACPIsolationTests {
    @Test
    func runtimeClientRejectsAttachingDifferentRemoteSessionOnSameRuntime() async throws {
        let workingDirectory = makeTemporaryDirectory()
        let client = try ACPExternalAgentRuntimeClient(
            launchConfiguration: ACPExternalAgentLaunchConfiguration(
                command: "/usr/bin/ruby",
                arguments: ["-rjson", "-e", loadSessionOnlyRubyAgentScript],
                environmentOverrides: [:],
                currentDirectoryURL: workingDirectory
            ),
            terminalRuntime: TerminalTaskRuntime.makeForTests(),
            authorizationPolicy: ToolAuthorizationPolicy(preset: .actLimited),
            eventSink: { _ in }
        )

        let firstHandshake = try await client.ensureSession(
            workingDirectory: workingDirectory.path,
            remoteSessionID: "remote-a"
        )

        #expect(firstHandshake.remoteSessionID == "remote-a")

        do {
            _ = try await client.ensureSession(
                workingDirectory: workingDirectory.path,
                remoteSessionID: "remote-b"
            )
            #expect(Bool(false))
        } catch let error as ACPExternalAgentRuntimeError {
            #expect(error == .sessionAlreadyAttached(current: "remote-a", requested: "remote-b"))
        }

        await client.close()
    }

    @Test
    func localClientHandlerDoesNotExposeTerminalAcrossSessions() async throws {
        let runtimeA = TerminalTaskRuntime.makeForTests()
        let runtimeB = TerminalTaskRuntime.makeForTests()
        let handler = ACPLocalClientHandler(
            authorizationPolicy: ToolAuthorizationPolicy(preset: .actLimited),
            terminalRuntimeProvider: { sessionID in
                switch sessionID {
                case "session-a":
                    return runtimeA
                case "session-b":
                    return runtimeB
                default:
                    return runtimeA
                }
            }
        )

        let created = try #require(try await handler.handleCreateTerminal(
            ACPCreateTerminalRequest(
                meta: nil,
                args: ["-c", "printf 'hello from a'"] ,
                command: "/bin/sh",
                cwd: nil,
                env: nil,
                outputByteLimit: nil,
                sessionID: "session-a"
            )
        ))

        _ = try #require(try await handler.handleWaitForTerminalExit(
            ACPWaitForTerminalExitRequest(meta: nil, sessionID: "session-a", terminalID: created.terminalID)
        ))

        do {
            _ = try await handler.handleTerminalOutput(
                ACPTerminalOutputRequest(meta: nil, sessionID: "session-b", terminalID: created.terminalID)
            )
            #expect(Bool(false))
        } catch let error as ACPRequestError {
            #expect(error == .resourceNotFound(uri: created.terminalID))
        }

        let terminalOutput = try #require(try await handler.handleTerminalOutput(
            ACPTerminalOutputRequest(meta: nil, sessionID: "session-a", terminalID: created.terminalID)
        ))
        #expect(terminalOutput.output.contains("hello from a"))

        _ = try #require(try await handler.handleReleaseTerminal(
            ACPReleaseTerminalRequest(meta: nil, sessionID: "session-a", terminalID: created.terminalID)
        ))
    }

    private func makeTemporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private var loadSessionOnlyRubyAgentScript: String {
        #"""
initialize_request = JSON.parse(STDIN.gets)

initialize_response = {
  "jsonrpc" => "2.0",
  "id" => initialize_request.fetch("id"),
  "result" => {
    "protocolVersion" => 1,
    "agentCapabilities" => {
      "loadSession" => true
    },
    "agentInfo" => {
      "name" => "test-agent",
      "version" => "0.1.0"
    }
  }
}
STDOUT.write(JSON.generate(initialize_response) + "\n")
STDOUT.flush

while (line = STDIN.gets)
  request = JSON.parse(line)
  case request["method"]
  when "loadSession"
    response = {
      "jsonrpc" => "2.0",
      "id" => request.fetch("id"),
      "result" => {
        "configOptions" => [],
        "modes" => nil
      }
    }
    STDOUT.write(JSON.generate(response) + "\n")
    STDOUT.flush
  when "newSession"
    response = {
      "jsonrpc" => "2.0",
      "id" => request.fetch("id"),
      "result" => {
        "sessionId" => "remote-fallback",
        "configOptions" => [],
        "modes" => nil
      }
    }
    STDOUT.write(JSON.generate(response) + "\n")
    STDOUT.flush
  when "prompt"
    response = {
      "jsonrpc" => "2.0",
      "id" => request.fetch("id"),
      "result" => {
        "stopReason" => "end_turn"
      }
    }
    STDOUT.write(JSON.generate(response) + "\n")
    STDOUT.flush
  when "cancel"
  else
    response = {
      "jsonrpc" => "2.0",
      "id" => request.fetch("id"),
      "result" => {}
    }
    STDOUT.write(JSON.generate(response) + "\n")
    STDOUT.flush
  end
end
"""#
    }
}

@MainActor
struct ACPExternalAgentRuntimeClientConcurrencyTests {
  @Test
  func externalRuntimeSnapshotsAreDetachedTaskSafe() async throws {
    let payload = Data(
      #"{"loadSession":true,"supportsSessionModelOverride":false,"agentVersion":"1.2.3"}"#.utf8
    )

    let result = try await Task.detached {
      let snapshot = try JSONDecoder().decode(ACPExternalAgentCapabilitySnapshot.self, from: payload)
      let handshake = ACPExternalAgentSessionHandshake(
        remoteSessionID: "remote-detached",
        capabilities: snapshot,
        configurationSnapshot: ACPExternalAgentSessionConfigurationSnapshot(configOptions: [], modes: nil)
      )
      return (
        snapshot.loadSession,
        snapshot.supportsSessionModelOverride,
        handshake.remoteSessionID
      )
    }.value

    #expect(result.0 == true)
    #expect(result.1 == false)
    #expect(result.2 == "remote-detached")
  }

    @Test
    func initializeDoesNotDependOnMainActorAvailability() async throws {
        let workingDirectory = makeTemporaryDirectory()
        let client = try await ACPExternalAgentRuntimeClient(
            launchConfiguration: ACPExternalAgentLaunchConfiguration(
                command: "/usr/bin/ruby",
                arguments: ["-rjson", "-e", initializeOnlyRubyAgentScript],
                environmentOverrides: [:],
                currentDirectoryURL: workingDirectory
            ),
            terminalRuntime: TerminalTaskRuntime.makeForTests(),
            authorizationPolicy: ToolAuthorizationPolicy(preset: .actLimited),
            initializeTimeoutNanoseconds: 5_000_000_000,
            eventSink: { _ in }
        )

        let blockerStarted = AsyncStream.makeStream(of: Void.self)
        let blocker = Task {
            await MainActor.run {
                blockerStarted.continuation.yield(())
                blockerStarted.continuation.finish()
                usleep(1_000_000)
            }
        }

        var blockerIterator = blockerStarted.stream.makeAsyncIterator()
        _ = await blockerIterator.next()

        let clock = ContinuousClock()
        let start = clock.now
        let capabilities = try await client.initializeIfNeeded()
        let elapsed = start.duration(to: clock.now)
        let loadSession = await capabilities.loadSession

        #expect(loadSession)
        #expect(elapsed < .seconds(1))

        _ = await blocker.value
        await client.close()
    }

        @Test
        func providerRuntimeClientConstructionDoesNotDependOnMainActorAvailability() async throws {
          let providers = await MainActor.run { () -> [(String, AsyncRuntimeClientBuildInvoker)] in
            let permissionCenter = ACPPermissionCenter()
            let authorizationPolicy = ToolAuthorizationPolicy(preset: .actLimited)
            let configuration = ACPCLIConfiguration(
              executablePath: "/usr/bin/env",
              defaultModel: "",
              defaultApprovalMode: ACPCLIConfiguration.externalProviderDefaultApprovalMode
            )

            let copilot = GitHubCopilotCLIExecutionProvider(
              terminalRuntimeFactory: { _, _ in TerminalTaskRuntime.makeForTests() },
              permissionCenter: permissionCenter
            )
            let openCode = OpenCodeCLIExecutionProvider(
              terminalRuntimeFactory: { _, _ in TerminalTaskRuntime.makeForTests() },
              permissionCenter: permissionCenter
            )
            let claudeAdapter = ClaudeAdapterCLIExecutionProvider(
              terminalRuntimeFactory: { _, _ in TerminalTaskRuntime.makeForTests() },
              permissionCenter: permissionCenter
            )

            return [
              (
                "copilot",
                AsyncRuntimeClientBuildInvoker {
                  _ = try await copilot.buildRuntimeClient(
                    configuration: configuration,
                    localSessionID: "runtime-build-copilot",
                    workingDirectory: FileManager.default.temporaryDirectory.path,
                    authorizationPolicy: authorizationPolicy,
                    permissionResolver: { _, _ in nil },
                    updateSink: { _ in }
                  )
                }
              ),
              (
                "openCode",
                AsyncRuntimeClientBuildInvoker {
                  _ = try await openCode.buildRuntimeClient(
                    configuration: configuration,
                    localSessionID: "runtime-build-opencode",
                    workingDirectory: FileManager.default.temporaryDirectory.path,
                    authorizationPolicy: authorizationPolicy,
                    permissionResolver: { _, _ in nil },
                    updateSink: { _ in }
                  )
                }
              ),
              (
                "claudeAdapter",
                AsyncRuntimeClientBuildInvoker {
                  _ = try await claudeAdapter.buildRuntimeClient(
                    configuration: configuration,
                    localSessionID: "runtime-build-claude",
                    workingDirectory: FileManager.default.temporaryDirectory.path,
                    authorizationPolicy: authorizationPolicy,
                    permissionResolver: { _, _ in nil },
                    updateSink: { _ in }
                  )
                }
              )
            ]
          }

          for (name, invoker) in providers {
            let blockerStarted = AsyncStream.makeStream(of: Void.self)
            let blocker = Task {
              await MainActor.run {
                blockerStarted.continuation.yield(())
                blockerStarted.continuation.finish()
                usleep(1_000_000)
              }
            }

            var blockerIterator = blockerStarted.stream.makeAsyncIterator()
            _ = await blockerIterator.next()

            let clock = ContinuousClock()
            let start = clock.now
            try await Task.detached {
              try await invoker.run()
            }.value
            let elapsed = start.duration(to: clock.now)

            #expect(elapsed < .seconds(1), Comment(rawValue: "provider=\(name) elapsed=\(String(describing: elapsed))"))

            _ = await blocker.value
          }
        }

        @Test
        func providerUpdateSinkDoesNotBlockInitializeWhenMainActorIsBusy() async throws {
          let agentScript = initializeAfterNotificationRubyAgentScript
          let provider = await MainActor.run {
            GitHubCopilotCLIExecutionProvider(
              terminalRuntimeFactory: { _, _ in TerminalTaskRuntime.makeForTests() },
              permissionCenter: ACPPermissionCenter(),
              runtimeClientFactory: { _, terminalRuntime, authorizationPolicy, permissionResolver, updateSink in
                try ACPExternalAgentRuntimeClient(
                  launchConfiguration: ACPExternalAgentLaunchConfiguration(
                    command: "/usr/bin/ruby",
                    arguments: ["-rjson", "-e", agentScript],
                    environmentOverrides: [:],
                    currentDirectoryURL: FileManager.default.temporaryDirectory
                  ),
                  terminalRuntime: terminalRuntime,
                  authorizationPolicy: authorizationPolicy,
                  initializeTimeoutNanoseconds: 5_000_000_000,
                  permissionResolver: permissionResolver,
                  eventSink: updateSink
                )
              }
            )
          }

          let runtimeClient = try await provider.buildRuntimeClient(
            configuration: ACPCLIConfiguration(
              executablePath: "/usr/bin/false",
              defaultModel: "",
              defaultApprovalMode: ACPCLIConfiguration.externalProviderDefaultApprovalMode
            ),
            localSessionID: "update-sink-isolation",
            workingDirectory: FileManager.default.temporaryDirectory.path,
            authorizationPolicy: ToolAuthorizationPolicy(preset: .actLimited),
            permissionResolver: { _, _ in nil },
            updateSink: { _ in }
          )

          guard let client = runtimeClient as? ACPExternalAgentRuntimeClient else {
            Issue.record("Expected ACPExternalAgentRuntimeClient runtime")
            return
          }

          let blockerStarted = AsyncStream.makeStream(of: Void.self)
          let blocker = Task {
            await MainActor.run {
              blockerStarted.continuation.yield(())
              blockerStarted.continuation.finish()
              usleep(1_000_000)
            }
          }

          var blockerIterator = blockerStarted.stream.makeAsyncIterator()
          _ = await blockerIterator.next()

          let clock = ContinuousClock()
          let start = clock.now
          let capabilities = try await Task.detached {
            try await client.initializeIfNeeded()
          }.value
          let elapsed = start.duration(to: clock.now)

          #expect(capabilities.loadSession)
          #expect(elapsed < .seconds(1), Comment(rawValue: "elapsed=\(String(describing: elapsed))"))

          _ = await blocker.value
          await client.close()
        }

    private func makeTemporaryDirectory() -> URL {
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
      try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      return directory
    }

    private final class AsyncRuntimeClientBuildInvoker: @unchecked Sendable {
      private let operation: () async throws -> Void

      init(_ operation: @escaping () async throws -> Void) {
        self.operation = operation
      }

      func run() async throws {
        try await operation()
      }
    }

    private var initializeOnlyRubyAgentScript: String {
      #"""
  initialize_request = JSON.parse(STDIN.gets)

  initialize_response = {
    "jsonrpc" => "2.0",
    "id" => initialize_request.fetch("id"),
    "result" => {
    "protocolVersion" => 1,
    "agentCapabilities" => {
      "loadSession" => true
    },
    "agentInfo" => {
      "name" => "test-agent",
      "version" => "0.1.0"
    }
    }
  }
  STDOUT.write(JSON.generate(initialize_response) + "\n")
  STDOUT.flush
  sleep
  """#
    }

    private var initializeAfterNotificationRubyAgentScript: String {
      #"""
  initialize_request = JSON.parse(STDIN.gets)

  session_update = {
    "jsonrpc" => "2.0",
    "method" => "session/update",
    "params" => {
      "sessionId" => "remote-update-session",
      "update" => {
        "sessionUpdate" => "available_commands_update",
        "availableCommands" => [
          {
            "name" => "plan",
            "description" => "Create a plan",
            "input" => {
              "hint" => "what to plan"
            }
          }
        ]
      }
    }
  }

  initialize_response = {
    "jsonrpc" => "2.0",
    "id" => initialize_request.fetch("id"),
    "result" => {
      "protocolVersion" => 1,
      "agentCapabilities" => {
        "loadSession" => true
      },
      "agentInfo" => {
        "name" => "test-agent",
        "version" => "0.1.0"
      }
    }
  }

  STDOUT.write(JSON.generate(session_update) + "\n")
  STDOUT.flush
  STDOUT.write(JSON.generate(initialize_response) + "\n")
  STDOUT.flush
  sleep
  """#
    }
  }