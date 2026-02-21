#!/usr/bin/env bash
# cc.sh — Claude Code Shell Shortcuts
# Source from ~/.zshrc. Provides: cc, ccc, ccr, ccf, cc-yolo, cc-edit,
# cc-plan, cc-read, cc-opus, cc-sonnet, cc-haiku, cc-q, cc-pipe,
# cc-review, cc-review-branch, cc-explain, cc-msg, cc-deep, cc-fast,
# cc-debug, cc-budget, cc-sandbox, cc-nobash, cc-nonet, cc-jail,
# cc-mono, cc-wt, cc-pr, cc-help
#
# Note: `cc` shadows the system C compiler (cc -> clang on macOS).
# If you need the C compiler, use `clang` or `gcc` directly,
# or rename the cc() function below to something like `cl`.

# ─── Core Session ────────────────────────────────────────────────────────────

cc() {
  claude "$@"
}

ccc() {
  claude --continue "$@"
}

ccr() {
  claude --resume "$@"
}

ccf() {
  claude --continue --fork-session "$@"
}

# ─── Permission Modes ────────────────────────────────────────────────────────

cc-yolo() {
  claude --dangerously-skip-permissions "$@"
}

cc-edit() {
  claude --permission-mode acceptEdits "$@"
}

cc-plan() {
  claude --permission-mode plan "$@"
}

cc-read() {
  claude --allowed-tools "Read Glob Grep LS WebSearch WebFetch" "$@"
}

# ─── Model Selection ─────────────────────────────────────────────────────────

cc-opus() {
  claude --model opus "$@"
}

cc-sonnet() {
  claude --model sonnet "$@"
}

cc-haiku() {
  claude --model haiku "$@"
}

# ─── One-Shot / Piping ───────────────────────────────────────────────────────

cc-q() {
  claude -p --no-session-persistence --model haiku "$*"
}

cc-pipe() {
  local prompt="$1"; shift
  "$@" 2>&1 | claude -p "$prompt"
}

cc-review() {
  local diff
  diff="$(git diff --cached 2>/dev/null)"
  if [ -z "$diff" ]; then
    diff="$(git diff 2>/dev/null)"
  fi
  if [ -z "$diff" ]; then
    echo "No staged or unstaged changes to review." >&2
    return 1
  fi
  echo "$diff" | claude -p "Review this diff. Focus on bugs, logic errors, and security issues. Be concise."
}

cc-review-branch() {
  local base="${1:-main}"
  local diff
  diff="$(git diff "$base"...HEAD 2>/dev/null)"
  if [ -z "$diff" ]; then
    echo "No diff between HEAD and $base." >&2
    return 1
  fi
  echo "$diff" | claude -p "Review this branch diff against $base. Focus on bugs, logic errors, and security issues."
}

cc-explain() {
  if [ -z "$1" ]; then
    echo "Usage: cc-explain <file>" >&2
    return 1
  fi
  if [ ! -f "$1" ]; then
    echo "Error: File '$1' not found." >&2
    return 1
  fi
  cat "$1" | claude -p "Explain this code. Be concise, focus on what's non-obvious."
}

cc-msg() {
  local diff
  diff="$(git diff --cached 2>/dev/null)"
  if [ -z "$diff" ]; then
    echo "No staged changes. Stage files first with git add." >&2
    return 1
  fi

  local msg
  msg="$(echo "$diff" | claude -p --model haiku \
    "Write a concise git commit message for this diff. One subject line (<72 chars), blank line, optional body. No backticks, no markdown formatting. Just the raw message text.")"

  echo ""
  echo "$msg"
  echo ""
  printf "Use this message? [y/N/e(dit)] "
  read -r reply
  case "$reply" in
    y|Y) git commit -m "$msg" ;;
    e|E) git commit -e -m "$msg" ;;
    *)   echo "Aborted." ;;
  esac
}

# ─── Compound Modes ──────────────────────────────────────────────────────────

cc-deep() {
  claude --dangerously-skip-permissions --model opus --continue "$@"
}

cc-fast() {
  claude --model haiku --permission-mode acceptEdits "$@"
}

cc-debug() {
  claude --debug --verbose --continue "$@"
}

cc-budget() {
  local budget="${1:-2.00}"
  [ $# -gt 0 ] && shift
  claude --dangerously-skip-permissions --max-budget-usd "$budget" -p "$*"
}

# ─── Sandbox Modes ───────────────────────────────────────────────────────────

cc-sandbox() {
  # Full autonomy inside a real sandbox (Docker/VM). No permission prompts.
  # Intended for environments where the container IS the safety boundary.
  claude --dangerously-skip-permissions --model "${CC_SANDBOX_MODEL:-sonnet}" "$@"
}

cc-nobash() {
  # Can read + edit files but cannot execute anything. Good for reviewing
  # and making edits you'll verify yourself before running.
  claude --disallowed-tools "Bash" "$@"
}

cc-nonet() {
  # No network access — can't search the web or fetch URLs.
  # Useful when working on sensitive code or offline-first workflows.
  claude --disallowed-tools "WebSearch WebFetch" "$@"
}

cc-jail() {
  # Maximum restriction: read-only, no bash, no network.
  # Claude can only look at code and answer questions.
  claude --allowed-tools "Read Glob Grep LS" "$@"
}

# ─── Multi-Repo ──────────────────────────────────────────────────────────────

cc-mono() {
  if [ $# -eq 0 ]; then
    echo "Usage: cc-mono <dir1> [dir2] ... [-- claude args]" >&2
    echo "  Opens Claude with access to additional directories" >&2
    return 1
  fi

  local dirs=()
  local claude_args=()
  local past_separator=false

  for arg in "$@"; do
    if [ "$arg" = "--" ]; then
      past_separator=true
      continue
    fi
    if [ "$past_separator" = true ]; then
      claude_args+=("$arg")
    else
      dirs+=(--add-dir "$arg")
    fi
  done

  claude "${dirs[@]}" "${claude_args[@]}"
}

# ─── Integrations ────────────────────────────────────────────────────────────

cc-wt() {
  local name="${1:-}"
  if [ -n "$name" ]; then
    claude --worktree "$name" --tmux
  else
    claude --worktree --tmux
  fi
}

cc-pr() {
  if [ -z "$1" ]; then
    claude --from-pr
  else
    claude --from-pr "$1"
  fi
}

# ─── Help ─────────────────────────────────────────────────────────────────────

cc-help() {
  cat <<'HELP'
Claude Code Shell Shortcuts
============================

Core Session:
  cc [args]                 claude (passthrough, shadows system cc compiler)
  ccc [args]                Continue last conversation in this directory
  ccr [search]              Resume a conversation (interactive picker)
  ccf [args]                Fork from last conversation (new session ID)

Permission Modes:
  cc-yolo [args]            Skip all permission checks (use in trusted dirs)
  cc-edit [args]            Auto-accept file edits, still prompt for bash
  cc-plan [args]            Plan mode — must approve before implementation
  cc-read [args]            Read-only — no edits, no bash, just exploration

Model Selection:
  cc-opus [args]            Use Opus (most capable, slowest)
  cc-sonnet [args]          Use Sonnet (balanced)
  cc-haiku [args]           Use Haiku (fastest, cheapest)

One-Shot / Piping:
  cc-q <question>           Quick question via Haiku, no session saved
  cc-pipe <prompt> <cmd>    Pipe command output to Claude for analysis
                              e.g. cc-pipe "explain these errors" npm test
  cc-review                 Review staged (or unstaged) git diff
  cc-review-branch [base]   Review branch diff vs base (default: main)
  cc-explain <file>         Explain a file's code
  cc-msg                    Generate commit message from staged changes

Compound Modes:
  cc-deep [args]            Opus + yolo + continue — deep autonomous work
  cc-fast [args]            Haiku + acceptEdits — quick low-stakes tasks
  cc-debug [args]           Debug + verbose + continue — troubleshoot sessions
  cc-budget <$> <prompt>    Budget-capped one-shot (default $2.00)
                              e.g. cc-budget 5.00 "refactor auth module"

Sandbox Modes:                    (least restricted → most restricted)
  cc-sandbox [args]         Full autonomy, for use inside Docker/VM
                              Set CC_SANDBOX_MODEL=opus to override model
  cc-nobash [args]          Can read + edit files, but no shell execution
  cc-nonet [args]           No WebSearch or WebFetch — air-gapped from web
  cc-jail [args]            Read-only, no bash, no network — observe only
  cc-read [args]            (see Permission Modes — similar to jail + web)

Multi-Repo:
  cc-mono <dirs> [-- args]  Claude with access to additional directories
                              e.g. cc-mono ../shared-lib ../api -- --model opus

Integrations:
  cc-wt [name]              Claude in its own worktree + tmux pane
  cc-pr [number|url]        Resume or start from a GitHub PR

Composability:
  Model and permission functions pass through all args, so you can combine:
    cc-opus --continue                     Opus + continue
    cc-yolo --model opus                   Yolo + opus
    cc-edit --continue --model haiku       Accept edits + continue + haiku

  cc-help                   Show this help message
HELP
}
