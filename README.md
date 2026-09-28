# Agent Watcher

Native macOS dashboard and menu bar app for observing AI-agent activity. Agent Watcher is designed around an agent-neutral activity contract and does not require external hardware. Codex CLI and Antigravity (Gemini) are the built-in input integrations; other agents can be added without changing the dashboard or status rules.

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
- `AgentIntegration` owns agent-specific setup and event translation. `CodexCLIIntegration` and `AntigravityIntegration` are the built-in implementations.
- `ActivitySummary` converts all activities into a device-neutral `AttentionSignal`.
- The window and menu bar render that signal. Optional hardware or notification adapters implement `ActivityOutput`; none is required.
- Integrations can optionally provide account-level allowance data through `AgentUsageProvider`; usage is not modeled as a per-session quota when sessions share the same account limit.

Source files follow those boundaries directly:

```text
Sources/
├── Inputs/                AI-agent-specific adapters
│   ├── Codex/
│   └── Antigravity/
├── Core/                  agent- and device-neutral domain logic
├── App/                   macOS store, menu bar, and dashboard UI
└── Outputs/               optional device/notification adapters
```

Dependencies point inward: inputs and outputs may use `Core`, while `Core`
must never import concepts from a specific agent or external device.

The application icon source is `assets/logo.png`. The build script generates the complete macOS `.icns` resource automatically.

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

The dashboard presents activities as a board: idle work appears in **Backlog**, running work in **In Development**, attention requests in **Blocker**, and completed work in **Ended**. Ended cards are automatically removed from the board and menu after 10 minutes; no manual refresh is required.

The Codex adapter also displays the latest five-hour and weekly allowance found in local Codex session metadata. Antigravity model allowances are read on a best-effort basis from its running local service. These metadata formats are not public APIs. Agent Watcher reads only the minimum quota fields and does not retain prompts, commands, or model responses. If usage metadata is absent or changes format, activity monitoring continues without the usage card.

## Install from GitHub Releases

Users do not need Xcode, Python, or external hardware:

1. Open the repository's **Releases** page.
2. Download `Agent-Watcher-x.y.z.pkg` from the latest release. Do not download GitHub's automatic **Source code** archives for installation.
3. Double-click the `.pkg` and complete macOS Installer.
4. Open **Agent Watcher** from `/Applications`.
5. For the built-in integrations, run `/hooks` in Codex CLI or Antigravity to review installed lifecycle hooks.

Tagged release packages are Developer ID signed, submitted to Apple's notary service, and stapled before they are published. Consequently, a tag build fails instead of publishing an unsigned or unnotarized public installer.

## Build and release

For a local build on a Mac with Xcode Command Line Tools:

```sh
VERSION=0.1.2 bash build-macos.sh
```

The installer is written to `dist/Agent-Watcher-0.1.0.pkg`. A local build is ad-hoc signed and intended only for development. On first launch, adapters configure their lifecycle hooks (`~/.codex/hooks.json` for Codex CLI and `~/.gemini/config/hooks.json` for Antigravity), preserving existing hooks and making a backup when changing files.

The workflow at `.github/workflows/release.yml` has two modes:

- **Actions → Build and release macOS installer → Run workflow** builds a development `.pkg` and stores it as a workflow artifact for 14 days. It does not publish a GitHub Release and may be blocked by Gatekeeper.
- Pushing a semantic-version tag such as `v0.1.0` builds, signs, notarizes, staples, validates, and publishes the `.pkg` on GitHub Releases.

Configure these repository secrets under **Settings → Secrets and variables → Actions** before pushing a release tag:

| Secret | Required value |
| --- | --- |
| `APPLE_SIGNING_P12_BASE64` | Base64-encoded `.p12` containing the Developer ID Application and Developer ID Installer certificates and their private keys |
| `APPLE_SIGNING_P12_PASSWORD` | Password used when exporting that `.p12` |
| `APPLE_APP_IDENTITY` | Full identity name, for example `Developer ID Application: Example (TEAMID)` |
| `APPLE_INSTALLER_IDENTITY` | Full identity name, for example `Developer ID Installer: Example (TEAMID)` |
| `APPLE_NOTARY_APPLE_ID` | Apple ID used for notarization |
| `APPLE_NOTARY_TEAM_ID` | Apple Developer Team ID |
| `APPLE_NOTARY_PASSWORD` | App-specific password for the notarization Apple ID |

Create and publish a release with:

```sh
git tag v0.1.0
git push origin v0.1.0
```

The workflow uses the version without the `v` prefix for the package filename. It requires all seven secrets for tag builds and has `contents: write` permission so the repository's `GITHUB_TOKEN` can create or update the matching GitHub Release.

## Extension points

To support another AI agent, implement `AgentIntegration` for setup and translate its events into the snapshot contract. To support hardware or notifications, implement `ActivityOutput` and consume `AttentionSignal` without adding device concepts to the domain.
