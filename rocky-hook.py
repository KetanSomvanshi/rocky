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


def tmux_client(tmux_env):
    """(pid, tty) of the most recently active client attached to our tmux
    server. Inside tmux the process ancestry dead-ends at the server (a child
    of launchd), so the hosting terminal must be found via the client."""
    sock = tmux_env.split(",")[0]
    try:
        out = subprocess.run(
            ["tmux", "-S", sock, "list-clients", "-F",
             "#{client_activity} #{client_pid} #{client_tty}"],
            capture_output=True, text=True, timeout=2,
        ).stdout.strip()
    except Exception:
        return None, None
    best, best_at = (None, None), -1
    for line in out.splitlines():
        parts = line.split()
        if len(parts) != 3:
            continue
        try:
            at, pid = int(parts[0]), int(parts[1])
        except ValueError:
            continue
        if at > best_at:
            best_at, best = at, (pid, parts[2])
    return best


def proc_env(pid, var):
    """Read one environment variable from a running process via `ps eww`."""
    try:
        out = subprocess.run(
            ["ps", "eww", "-p", str(pid)],
            capture_output=True, text=True, timeout=2,
        ).stdout
    except Exception:
        return None
    for tok in out.split():
        if tok.startswith(var + "="):
            return tok[len(var) + 1:] or None
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


def tool_detail(tool_name, tool_input, max_len=500):
    """Human string describing what a tool is doing — long enough to be the
    *actual* permission-prompt text (a full command/pattern), not a teaser."""
    if not isinstance(tool_input, dict):
        return ""
    if tool_name == "Bash":
        return tool_input.get("command", "")[:max_len]
    for key in ("file_path", "path", "pattern", "query", "url", "prompt"):
        if key in tool_input and isinstance(tool_input[key], str):
            val = tool_input[key]
            if key in ("file_path", "path"):
                val = os.path.basename(val)
            return val[:max_len]
    return ""


def read_transcript_tail(path, max_bytes=131072):
    """Parse the tail of the JSONL transcript into a list of JSON objects
    (oldest first). One read shared by every transcript-derived signal below;
    best-effort, returns [] on any trouble. The first line may be a partial
    record (we seek to an arbitrary byte) — it simply fails to parse and is
    skipped."""
    if not path or not os.path.exists(path):
        return []
    try:
        with open(path, "rb") as f:
            f.seek(0, os.SEEK_END)
            size = f.tell()
            f.seek(max(0, size - max_bytes))
            tail = f.read().decode("utf-8", "ignore")
    except OSError:
        return []
    objs = []
    for line in tail.splitlines():
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            objs.append(json.loads(line))
        except ValueError:
            continue
    return objs


def has_fresh_reply(objs):
    """True once a text-bearing assistant message appears after the last real
    user prompt — i.e. the turn's reply has actually landed in the transcript.
    Used to beat the flush race at Stop: the hook can fire before Claude has
    written the final assistant message, which would leave the story, outcome
    and context estimate a full turn stale until the next event."""
    last_prompt = -1
    for i, o in enumerate(objs):
        if _is_user_prompt(o):
            last_prompt = i
    for o in objs[last_prompt + 1:]:
        if o.get("type") != "assistant":
            continue
        content = o.get("message", {}).get("content", [])
        if isinstance(content, str) and content.strip():
            return True
        if isinstance(content, list) and any(
                isinstance(b, dict) and b.get("type") == "text" and b.get("text", "").strip()
                for b in content):
            return True
    return False


def transcript_summary(objs, max_len=600):
    """The last assistant text — a short, human 'what this session is
    saying' peek. Empty when there's nothing to show."""
    for obj in reversed(objs):
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


def _is_user_prompt(obj):
    """A real user turn (typed prompt), not a tool_result the harness injects
    as a synthetic 'user' message."""
    if obj.get("type") != "user":
        return False
    content = obj.get("message", {}).get("content", "")
    if isinstance(content, str):
        return bool(content.strip())
    if isinstance(content, list):
        return any(isinstance(b, dict) and b.get("type") == "text" for b in content)
    return False


# Tools that mutate files — used to summarise what a finished turn did.
EDIT_TOOLS = {"Edit", "Write", "MultiEdit", "NotebookEdit"}


def transcript_outcome(objs):
    """A one-line summary of what the session actually did *this turn* — the
    files it changed and commands it ran since the last user prompt — so a
    finished tab shows an outcome, not just 'your turn'. Empty when the turn
    touched nothing summarisable."""
    # Bound to the current turn: everything after the last real user prompt.
    start = 0
    for i in range(len(objs) - 1, -1, -1):
        if _is_user_prompt(objs[i]):
            start = i
            break
    files = set()
    commands = 0
    for obj in objs[start:]:
        if obj.get("type") != "assistant":
            continue
        content = obj.get("message", {}).get("content", [])
        if not isinstance(content, list):
            continue
        for b in content:
            if not isinstance(b, dict) or b.get("type") != "tool_use":
                continue
            name = b.get("name", "")
            inp = b.get("input", {})
            if not isinstance(inp, dict):
                inp = {}
            if name in EDIT_TOOLS:
                p = inp.get("file_path") or inp.get("path") or inp.get("notebook_path")
                if isinstance(p, str) and p:
                    files.add(p)
            elif name == "Bash":
                commands += 1
    parts = []
    if files:
        n = len(files)
        parts.append(f"{n} file{'s' if n != 1 else ''} changed")
    if commands:
        parts.append(f"{commands} command{'s' if commands != 1 else ''}")
    return " · ".join(parts)


def user_context_limit():
    """The context-window size, best-effort. The transcript never records the
    1M-beta `[1m]` suffix (it's a runtime flag), so read it from where it *is*
    persisted: an explicit override, else Claude's own selected-model setting.
    Returns the token limit, or None when nothing says otherwise (→ 200K)."""
    override = os.environ.get("ROCKY_CONTEXT_LIMIT")
    if override and override.isdigit():
        return int(override)
    for rel in ("settings.json", "settings.local.json"):
        try:
            with open(os.path.expanduser("~/.claude/" + rel)) as f:
                model = json.load(f).get("model") or ""
        except (OSError, ValueError):
            continue
        if "[1m]" in model.lower():
            return 1000000
    return None


def transcript_context(objs, big_limit=1000000, default_limit=200000):
    """Estimate how full the context window is from the most recent assistant
    turn's token usage. Returns (used_tokens, limit_tokens); (0, 0) when the
    transcript carries no usage (so the meter hides rather than guessing)."""
    for obj in reversed(objs):
        if obj.get("type") != "assistant":
            continue
        msg = obj.get("message", {})
        usage = msg.get("usage")
        if not isinstance(usage, dict):
            continue
        # input + both cache buckets are the disjoint parts of the prompt sent;
        # add the response so the estimate reflects the window after this turn.
        used = (usage.get("input_tokens", 0)
                + usage.get("cache_read_input_tokens", 0)
                + usage.get("cache_creation_input_tokens", 0)
                + usage.get("output_tokens", 0))
        if not isinstance(used, (int, float)) or used <= 0:
            continue
        # Window size: usage already past 200K *proves* a larger window;
        # otherwise trust the user's configured 1M mode; else the 200K default.
        # (Over-reporting headroom is the safe error — a false "about to
        # compact" alarm is the one that costs trust.)
        limit = default_limit
        if used > default_limit or user_context_limit() == big_limit:
            limit = big_limit
        return int(used), limit
    return 0, 0


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

    # Focus handles: this hook runs as a child of the Claude process, so the
    # session's environment — including the terminal's deep-link vars — is
    # simply inherited. Captured here once; Rocky.app uses them at click time.
    tmux_env = os.environ.get("TMUX") or None
    tmux_pane = os.environ.get("TMUX_PANE") or None
    warp_url = os.environ.get("WARP_FOCUS_URL") or None
    kitty_socket = os.environ.get("KITTY_LISTEN_ON") or None
    kitty_window = os.environ.get("KITTY_WINDOW_ID") or None

    # term_app/tty are moderately expensive; cache them from the prior write.
    term_app = None
    tty = None
    prev_attended = 0
    prev_recent = []
    prev_outcome = ""
    try:
        with open(session_path) as f:
            prev = json.load(f)
        term_app = prev.get("term_app")
        tty = prev.get("tty")
        warp_url = warp_url or prev.get("warp_url")
        prev_attended = prev.get("attended_at", 0)
        prev_recent = prev.get("recent", []) or []
        prev_outcome = prev.get("outcome", "") or ""
    except (OSError, json.JSONDecodeError, ValueError):
        pass

    if tmux_env:
        # Host terminal = whatever the tmux *client* runs in; its tty is the
        # host tab's tty (what iTerm/Terminal scripting needs), and its env
        # carries the Warp deep link for the tab tmux is attached in.
        if not term_app or not tty:
            client_pid, client_tty = tmux_client(tmux_env)
            if client_pid:
                term_app = term_app or find_term_app(client_pid)
                tty = tty or client_tty
                if not warp_url:
                    warp_url = proc_env(client_pid, "WARP_FOCUS_URL")
    else:
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

    # Everything derived from the transcript shares one tail read. On Stop the
    # final assistant message may not be flushed the instant the hook fires, so
    # poll briefly until the reply lands — otherwise the story/outcome/context
    # would show the *previous* turn until the next event corrected them. Async
    # hook, so this waiting never delays Claude's turn.
    transcript_path = data.get("transcript_path", "")
    objs = read_transcript_tail(transcript_path)
    if event == "Stop":
        for _ in range(10):
            if has_fresh_reply(objs):
                break
            time.sleep(0.15)
            objs = read_transcript_tail(transcript_path)
    used_tokens, token_limit = transcript_context(objs)
    # The turn's outcome is meaningful only once it finishes (Stop); a fresh
    # prompt clears it, and every other event carries the last one forward.
    if event == "Stop":
        outcome = transcript_outcome(objs)
    elif event == "UserPromptSubmit":
        outcome = ""
    else:
        outcome = prev_outcome

    state = {
        "session_id": session_id,
        "status": status,
        "event": event,
        "tool": tool_name,
        "detail": tool_detail(tool_name, tool_input) if tool_name else "",
        "summary": transcript_summary(objs),
        "outcome": outcome,
        "context_tokens": used_tokens,
        "context_limit": token_limit,
        "recent": recent,
        "cwd": data.get("cwd", ""),
        "transcript": data.get("transcript_path", ""),
        "pid": claude_pid,
        "tty": tty,
        "term_app": term_app,
        "tmux": tmux_env,
        "tmux_pane": tmux_pane,
        "warp_url": warp_url,
        "kitty_socket": kitty_socket,
        "kitty_window": kitty_window,
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
