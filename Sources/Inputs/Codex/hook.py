#!/usr/bin/env python3
"""Codex adapter: translate a lifecycle hook to an Agent Watcher snapshot."""
import json
import os
import pathlib
import sys
import tempfile
import time


EVENT_STATUS = {
    "SessionStart": "standby",
    "UserPromptSubmit": "running",
    "PreToolUse": "running",
    "PostToolUse": "running",
    "PermissionRequest": "approval",
    "Stop": "standby",
    "Interrupt": "standby",
    "SessionEnd": "ended",
}


def main():
    try:
        data = json.load(sys.stdin)
        session_id = data.get("session_id")
        event = data.get("hook_event_name")
        if not isinstance(session_id, str) or not session_id or event not in EVENT_STATUS:
            return 0
        # Never persist prompt text, commands, or the full hook payload.
        root = pathlib.Path(os.environ.get(
            "AGENT_WATCHER_STATE_DIR",
            pathlib.Path.home() / "Library" / "Application Support" / "Agent Watcher" / "activities",
        ))
        root.mkdir(parents=True, exist_ok=True)
        safe_id = "".join(c for c in session_id if c.isalnum() or c in "-_")
        if not safe_id:
            return 0
        target = root / (safe_id + ".json")
        state = {
            "schema_version": 1,
            "id": session_id,
            "source_id": "codex-cli",
            "source_name": "Codex CLI",
            "workspace": data.get("cwd") if isinstance(data.get("cwd"), str) else "",
            "state": {"approval": "needs_attention", "standby": "idle"}.get(
                EVENT_STATUS[event], EVENT_STATUS[event]
            ),
            "detail": data.get("tool_name") if event == "PermissionRequest" else None,
            "updated_at": time.time(),
        }
        fd, tmp = tempfile.mkstemp(prefix=".state-", dir=root)
        try:
            with os.fdopen(fd, "w") as out:
                os.fchmod(out.fileno(), 0o600)
                json.dump(state, out)
            os.replace(tmp, target)
        finally:
            if os.path.exists(tmp):
                os.unlink(tmp)
    except Exception:
        # A status indicator must never prevent Codex from continuing.
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
