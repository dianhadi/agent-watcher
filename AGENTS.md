# AGENTS.md

## Project overview

Agent Watcher is a native macOS dashboard and menu bar application for monitoring AI-agent activity. The core must remain independent of any specific AI agent or external device. Codex CLI is currently the first integration, not the domain model.

The application targets macOS 13 or later and is built directly with `swiftc`; there is no Xcode project or Swift package.

## Architecture

- `Domain.swift` contains agent-neutral activity, status, usage, integration, and output contracts.
- `Sentinel.swift` contains the SwiftUI application, observable store, menu bar, board, and presentation logic.
- `HookRegistration.swift` is the Codex CLI integration installer.
- `CodexHook.swift` translates Codex lifecycle events into neutral activity snapshots.
- `CodexUsage.swift` reads Codex usage metadata on a best-effort basis.
- `hook.py` is a development/reference implementation of the Codex event translator.
- `build-macos.sh` builds universal arm64/x86_64 binaries and the local `.pkg` installer.
- `assets/logo.png` is the source image for the generated macOS application icon.

Keep source-specific behavior inside its integration adapter. UI and aggregation code must operate on `ActivitySnapshot`, `ActivityState`, `AttentionSignal`, and `AgentUsageSnapshot`, not native Codex event names.

## Activity behavior

The canonical states are:

- `idle`
- `needs_attention`
- `running`
- `ended`
- `unknown`

The dashboard presents four equal-width columns using the user-facing names **Idle**, **Needs Attention**, **Running**, and **Ended**. Ended activities remain visible for 10 minutes and then disappear automatically. The store polls every two seconds; do not add a manual refresh requirement.

The dashboard is a single-instance `Window`. Opening it from the menu bar must bring the existing window forward rather than create another window.

## Usage data

Usage allowances belong to an integration/account, not an individual session. Multiple Codex sessions share the same five-hour and weekly allowance.

The five-hour allowance is shown compactly. Additional limits, including weekly usage, remain collapsed by default.

Codex usage metadata is not a documented public API. Treat it as optional and best-effort:

- Read only the minimum required `rate_limits` metadata.
- Never retain or display prompts, commands, model responses, or complete session events.
- If local metadata is absent or changes format, omit usage while keeping activity monitoring functional.

## Privacy and safety

Persist only:

- Activity/session ID
- Integration source ID and display name
- Workspace path
- Neutral activity state
- Optional minimal detail such as a pending tool name
- Update timestamp

Do not persist prompts, command contents, model output, credentials, environment dumps, or complete hook payloads. Hook failures must never block the originating agent.

Write state atomically with owner-only permissions where applicable. Sanitize activity IDs before using them as filenames.

## Compatibility

The current schema is version 1 and is stored under:

```text
~/Library/Application Support/Agent Watcher/activities
```

Honor `AGENT_WATCHER_STATE_DIR` when set. Continue reading legacy Codex Sentinel snapshots unless a migration explicitly removes that compatibility.

Hook configuration is installed in `~/.codex/hooks.json`. Preserve unrelated user hooks and back up an existing file before modifying it. Codex requires users to review and trust non-managed hooks; do not bypass that security mechanism.

## UI conventions

- All user-facing copy is English.
- Agent monitoring is the primary visual hierarchy; usage and optional outputs are secondary.
- External hardware is optional. Do not make app operation depend on a USB, Bluetooth, serial, or network device.
- Use source names on cards so sessions from multiple integrations remain distinguishable.
- Keep menu bar information concise.

## Build and verification

Use the version default from `build-macos.sh`, or override it explicitly:

```sh
bash build-macos.sh
VERSION=0.1.1 bash build-macos.sh
```

The package is produced at:

```text
dist/Agent-Watcher-<version>.pkg
```

For restricted environments, place Swift module caches in a writable temporary directory:

```sh
cache_dir=/private/tmp/agent-watcher-module-cache
mkdir -p "$cache_dir"
CLANG_MODULE_CACHE_PATH="$cache_dir" \
SWIFT_MODULECACHE_PATH="$cache_dir" \
bash build-macos.sh
```

After changes, run at minimum:

```sh
bash -n build-macos.sh
git diff --check
```

For a completed build, verify that both application executables contain `arm64` and `x86_64` slices and that the app's ad-hoc signature is valid. A local installer is expected to report `no signature` unless Apple Developer signing identities are configured.

## Editing guidelines

- Preserve user changes and unrelated worktree modifications.
- Use `apply_patch` for source edits.
- Keep domain types agent-neutral and device-neutral.
- Add new agent support through `AgentIntegration` and optional `AgentUsageProvider` implementations.
- Add external destinations through `ActivityOutput` implementations.
- Update `build-macos.sh` whenever a new Swift source file must be compiled.
- Keep application icon generation reproducible from `assets/logo.png`; do not hand-edit generated `.icns` files.
- Update `README.md` when behavior, installation, privacy, or extension contracts change.
