//
//  ClaudeService+MemoryTool.swift
//  agentGui
//

import Foundation
import SwiftAnthropic

extension ClaudeService {

    // MARK: - Memory Write

    func executeMemoryWrite(input: MessageResponse.Content.Input) -> String {
        guard let content = input["content"]?.stringValue else {
            return "Error: missing 'content' parameter"
        }
        let modeString = input["mode"]?.stringValue ?? "append"
        let mode: MemoryWriteMode = modeString == "overwrite" ? .overwrite : .append
        switch ConfigDirectoryManager.shared.writeMemory(content: content, mode: mode) {
        case .success:
            return "Memory updated successfully (mode: \(modeString))."
        case .failure(let error):
            return "Error writing memory: \(error.localizedDescription)"
        }
    }
}
