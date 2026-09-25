# Agent Watcher

Native macOS dashboard and menu bar app for observing AI-agent activity. Agent Watcher is designed around an agent-neutral activity contract and does not require external hardware. Codex CLI is the first input integration; other agents can be added without changing the dashboard or status rules.

## Design

The app has three independent layers:

```text
agent-native events -> AgentIntegration adapter -> ActivitySnapshot
                                                   |
                                                   v
                                             ActivitySummary
                                                   |
                              +--------------------+------------------+
                              v                    v                  v
                         macOS window         menu bar       optional device
```

- `ActivitySnapshot` is the persisted, agent-neutral contract. It contains an ID, source, workspace, state, optional non-sensitive detail, and timestamp.
- `AgentIntegration` owns agent-specific setup and event translation. `CodexCLIIntegration` is currently the only implementation.
- `ActivitySummary` converts all activities into a device-neutral `AttentionSignal`.
- The window and menu bar render that signal. Optional hardware or notification adapters implement `ActivityOutput`; none is required.

The supported states are `needs_attention`, `running`, `idle`, `ended`, and `unknown`. Snapshot schema version 1 looks like this:

```json
{
  "schema_version": 1,
  "id": "agent-session-id",
  "source_id": "codex-cli",
  "source_name": "Codex CLI",
  "workspace": "/path/to/project",
  "state": "running",
  "detail": null,
  "updated_at": 1790298000
}
```

An integration writes one JSON file per activity to:

```text
~/Library/Application Support/Agent Watcher/activities
```

Set `AGENT_WATCHER_STATE_DIR` to use another directory. Version 0 snapshots from `Codex Sentinel` remain readable during migration. Integrations must not persist prompts, commands, model output, or complete native event payloads.

## Current status rules

| Agent activity | Neutral signal | Current visual treatment |
| --- | --- | --- |
| All active items need attention | `fullAttention` | Solid red |
| Some items need attention | `partialAttention` | Blinking yellow |
| At least one item is running | `active` | Blinking green |
| All active items are idle | `idle` | Solid blue |
| No active items | `inactive` | Off |

Ended activities and snapshots untouched for 12 hours do not count as active. Approvals remain in the originating agent. The current Codex adapter maps its lifecycle hooks to these neutral states; subagents that share a parent session ID remain a single activity.

## Install and build

For a local build on a Mac with Xcode Command Line Tools:

```sh
VERSION=0.1.0 bash build-macos.sh
```

The installer is written to `dist/Agent-Watcher-0.1.0.pkg`. On first launch the Codex adapter adds its lifecycle hooks to `~/.codex/hooks.json`, preserving existing hooks and making a backup when it changes the file. Run `/hooks` in Codex CLI to review and trust them.

For public distribution, sign the app and installer with `APPLE_APP_IDENTITY` and `APPLE_INSTALLER_IDENTITY`. Unsigned local builds are intended for development and may be blocked by Gatekeeper.

## Extension points

To support another AI agent, implement `AgentIntegration` for setup and translate its events into the snapshot contract. To support hardware or notifications, implement `ActivityOutput` and consume `AttentionSignal` without adding device concepts to the domain.

Session-window/quota information (for example a five-hour allowance) is intentionally not part of this iteration. It can later be modeled as source-provided metrics beside activity state and rendered in the menu bar without coupling the core to a particular provider.
