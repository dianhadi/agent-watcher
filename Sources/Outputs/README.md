# Outputs

Implement optional device, notification, or other status destinations here.
Each output should conform to `ActivityOutput` and consume only the neutral
`AttentionSignal`; it must not depend on Codex, Antigravity, or another input.

Agent Watcher's window and menu bar remain part of the app presentation in
`Sources/App` rather than an external output adapter.
