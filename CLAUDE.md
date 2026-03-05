# agentGui Development Guidelines

Auto-generated from all feature plans. Last updated: 2026-03-05

## Active Technologies

- Swift 6.0+ + SwiftAnthropic (Anthropic Claude API)
- SwiftData for persistence
- SwiftUI for macOS UI

## Project Structure

```text
agentGui/
  Models/         SwiftData models (Session, Message, ToolCall, AppSettings)
  Views/          SwiftUI views (ContentView, ChatView, SessionListView, MainSplitView)
  Services/       ClaudeService (SwiftAnthropic wrapper)
  Repositories/   Data access layer
  Utilities/      Error types, helpers
```

## Architecture

- `ClaudeService` (@Observable, @MainActor) — wraps SwiftAnthropic, handles streaming
- `AppSettings` (SwiftData @Model) — stores API key and selected model
- `Session` — a conversation thread
- `Message` — individual chat messages (user / agent / system)

## Commands

# Build: Open agentGui.xcodeproj in Xcode

## Code Style

Swift 6.0+: Follow standard conventions

## Recent Changes

- 002-swiftanthropic: Removed swift-acp, replaced with direct Anthropic Claude API via SwiftAnthropic

<!-- MANUAL ADDITIONS START -->
<!-- MANUAL ADDITIONS END -->
