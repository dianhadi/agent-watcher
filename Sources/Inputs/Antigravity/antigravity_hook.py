#!/usr/bin/env python3
"""Antigravity adapter: translate lifecycle events to an Agent Watcher snapshot."""
import json
import os
import pathlib
import sys
import tempfile
import time


def main():
    stdout_response = "{}"
    event_arg = sys.argv[1] if len(sys.argv) > 1 else None

    try:
        raw_input = sys.stdin.read()
        if not raw_input.strip():
            print(stdout_response)
            return 0

        data = json.loads(raw_input)
        conversation_id = data.get("conversationId") or data.get("id") or data.get("session_id")
        if not isinstance(conversation_id, str) or not conversation_id:
            print(stdout_response)
            return 0

        event = event_arg
        if not event:
            if "toolCall" in data:
                event = "PreToolUse"
            elif "terminationReason" in data:
                event = "Stop"
            elif "invocationNum" in data:
                event = "PreInvocation"
            elif "stepIdx" in data:
                event = "PostToolUse"
            else:
                event = "PreInvocation"

        safe_id = "".join(c for c in conversation_id if c.isalnum() or c in "-_")
        if not safe_id:
            print(stdout_response)
            return 0

        workspace_paths = data.get("workspacePaths") or []
        workspace = workspace_paths[0] if workspace_paths else data.get("workspace", data.get("cwd", ""))

        state = "running"
        detail = None

        if event == "SessionStart":
            state = "idle"
        elif event == "SessionEnd":
            state = "ended"
        elif event in ("PreInvocation", "PostInvocation"):
            state = "running"
        elif event == "PreToolUse":
            tool_call = data.get("toolCall") or {}
            tool_name = tool_call.get("name") or data.get("tool_name") or "tool approval"
            state = "needs_attention"
            detail = tool_name
        elif event == "PostToolUse":
            state = "running"
        elif event == "Stop":
            state = "idle"

        # Never persist prompt text, commands, or the full hook payload.
        root = pathlib.Path(os.environ.get(
            "AGENT_WATCHER_STATE_DIR",
            pathlib.Path.home() / "Library" / "Application Support" / "Agent Watcher" / "activities",
        ))
        root.mkdir(parents=True, exist_ok=True)
        target = root / (safe_id + ".json")

        snapshot = {
            "schema_version": 1,
            "id": conversation_id,
            "source_id": "antigravity",
            "source_name": "Antigravity",
            "workspace": workspace,
            "state": state,
            "updated_at": time.time(),
        }
        if detail:
            snapshot["detail"] = detail

        fd, tmp = tempfile.mkstemp(prefix=".state-", dir=root)
        try:
            with os.fdopen(fd, "w") as out:
                os.fchmod(out.fileno(), 0o600)
                json.dump(snapshot, out)
            os.replace(tmp, target)
        finally:
            if os.path.exists(tmp):
                os.unlink(tmp)
    except Exception:
        # A status indicator must never prevent Antigravity from continuing.
        pass

    print(stdout_response)
    return 0


if __name__ == "__main__":
    sys.exit(main())
