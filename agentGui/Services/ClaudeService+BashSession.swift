//
//  ClaudeService+BashSession.swift
//  agentGui
//

import Foundation

extension ClaudeService {

    // MARK: - Bash Session Management

    func getBashSession(
        for sessionId: String,
        workingDirectory: String?,
        environmentOverrides: [String: String]
    ) -> BashSession {
        if let existing = bashSessions[sessionId] { return existing }
        let newSession = BashSession()
        Task {
            await newSession.start(
                workingDirectory: workingDirectory,
                environmentOverrides: environmentOverrides
            )
        }
        bashSessions[sessionId] = newSession
        return newSession
    }

    func getBashTaskRegistry(for sessionId: String) -> BashTaskRegistry {
        if let existing = bashTaskRegistries[sessionId] { return existing }
        let registry = BashTaskRegistry()
        bashTaskRegistries[sessionId] = registry
        return registry
    }
}
