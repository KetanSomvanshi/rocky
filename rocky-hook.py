#!/usr/bin/env python3
"""
Rocky hook — turns Claude Code hook events into per-session state files.

Reads a hook event as JSON on stdin, maps it to a session status, and writes
~/.claude/rocky/sessions/<session_id>.json atomically. Rocky.app polls that
directory and animates a pixel cat per session.

Designed to run async (see settings.json) so it never adds latency to a turn.
Always exits 0 — a pet must never block or break Claude Code.
"""
import json
import os
import subprocess
import sys
import tempfile
import time

SESSIONS_DIR = os.path.expanduser("~/.claude/rocky/sessions")

# Terminal bundle identifiers we know how to focus later, keyed by the process
# name substring found while walking the ancestry of the Claude process.
TERM_APPS = {
    "Warp": "Warp",
    "iTerm": "iTerm2",
    "Terminal": "Terminal",
    "Ghostty": "Ghostty",
    "kitty": "kitty",
    "Alacritty": "Alacritty",
    "Code": "Code",
    "Cursor": "Cursor",
}


def find_term_app(start_pid):
    """Walk parent PIDs until we recognize a terminal emulator."""
    pid = start_pid
    for _ in range(12):  # bounded climb, guards against loops
        if not pid or pid == 1:
            break
        try:
            out = subprocess.run(
                ["ps", "-p", str(pid), "-o", "ppid=,comm="],
                capture_output=True, text=True, timeout=2,
            ).stdout.strip()
        except Exception:
            break
        if not out:
            break
        parts = out.split(None, 1)
        ppid = parts[0]
        comm = parts[1] if len(parts) > 1 else ""
        for needle, name in TERM_APPS.items():
            if needle.lower() in comm.lower():
                return name
        try:
            pid = int(ppid)
        except ValueError:
            break
    return None


def get_tty(claude_pid):
    try:
        tty = subprocess.run(
            ["ps", "-p", str(claude_pid), "-o", "tty="],
            capture_output=True, text=True, timeout=2,
        ).stdout.strip()
    except Exception:
        return None
    if tty and tty not in ("??", "-"):
        return tty if tty.startswith("/dev/") else "/dev/" + tty
    return None


def atomic_write(path, obj):
    d = os.path.dirname(path)
    os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=d, suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(obj, f)
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass


def tool_detail(tool_name, tool_input):
    """Short human string describing what a tool is doing."""
    if not isinstance(tool_input, dict):
        return ""
    if tool_name == "Bash":
        return tool_input.get("command", "")[:80]
    for key in ("file_path", "path", "pattern", "query", "url", "prompt"):
        if key in tool_input and isinstance(tool_input[key], str):
            val = tool_input[key]
            if key in ("file_path", "path"):
                val = os.path.basename(val)
            return val[:80]
    return ""


def transcript_summary(path, max_len=90):
    """The last assistant text from the JSONL transcript — a short, human
    'what this session is doing/saying' peek. Best-effort; empty on any trouble."""
    if not path or not os.path.exists(path):
        return ""
    try:
        with open(path, "rb") as f:
            f.seek(0, os.SEEK_END)
            size = f.tell()
            f.seek(max(0, size - 65536))          # last 64 KB is plenty
            tail = f.read().decode("utf-8", "ignore")
    except OSError:
        return ""
    for line in reversed(tail.splitlines()):
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            obj = json.loads(line)
        except ValueError:
            continue
        if obj.get("type") != "assistant":
            continue
        content = obj.get("message", {}).get("content", [])
        texts = []
        if isinstance(content, list):
            texts = [b.get("text", "") for b in content
                     if isinstance(b, dict) and b.get("type") == "text"]
        elif isinstance(content, str):
            texts = [content]
        text = " ".join(" ".join(texts).split())   # collapse whitespace
        if text:
            return text[:max_len]
    return ""


def main():
    try:
        data = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        sys.exit(0)

    session_id = data.get("session_id")
    if not session_id:
        sys.exit(0)

    event = data.get("hook_event_name", "")
    session_path = os.path.join(SESSIONS_DIR, f"{session_id}.json")

    # SessionEnd: remove the session's cat entirely.
    if event == "SessionEnd":
        try:
            os.unlink(session_path)
        except OSError:
            pass
        sys.exit(0)

    tool_name = data.get("tool_name")
    tool_input = data.get("tool_input", {})

    status = "idle"
    if event == "UserPromptSubmit":
        status = "processing"
    elif event == "PreToolUse":
        status = "running_tool"
    elif event == "PostToolUse":
        status = "processing"
    elif event == "Stop":
        status = "waiting_for_input"
    elif event == "SubagentStop":
        status = "processing"
    elif event == "SessionStart":
        status = "idle"
    elif event == "PreCompact":
        status = "compacting"
    elif event == "Notification":
        ntype = data.get("notification_type", "")
        if ntype == "permission_prompt":
            status = "needs_permission"
        elif ntype == "idle_prompt":
            status = "waiting_for_input"
        else:
            status = "notification"

    claude_pid = os.getppid()

    # term_app/tty are moderately expensive; cache them from the prior write.
    term_app = None
    tty = None
    prev_attended = 0
    prev_recent = []
    try:
        with open(session_path) as f:
            prev = json.load(f)
        term_app = prev.get("term_app")
        tty = prev.get("tty")
        prev_attended = prev.get("attended_at", 0)
        prev_recent = prev.get("recent", []) or []
    except (OSError, json.JSONDecodeError, ValueError):
        pass

    if not term_app:
        term_app = find_term_app(claude_pid)
    if not tty:
        tty = get_tty(claude_pid)

    now = time.time()
    # Rolling activity trace for the sparkline: recent event times, windowed to
    # the last 5 minutes and capped so the file stays small.
    recent = [t for t in prev_recent if isinstance(t, (int, float)) and now - t < 300]
    recent.append(now)
    recent = recent[-40:]

    state = {
        "session_id": session_id,
        "status": status,
        "event": event,
        "tool": tool_name,
        "detail": tool_detail(tool_name, tool_input) if tool_name else "",
        "summary": transcript_summary(data.get("transcript_path", "")),
        "recent": recent,
        "cwd": data.get("cwd", ""),
        "transcript": data.get("transcript_path", ""),
        "pid": claude_pid,
        "tty": tty,
        "term_app": term_app,
        "message": data.get("message", ""),
        "ts": now,
        # When the user submits a new prompt, they've clearly attended to this
        # session, so clear any prior "hot" mark by re-stamping attention.
        "attended_at": now if event == "UserPromptSubmit" else prev_attended,
    }

    atomic_write(session_path, state)
    sys.exit(0)


if __name__ == "__main__":
    main()
