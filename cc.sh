#!/usr/bin/env bash
# cc.sh — Claude Code Shell Shortcuts
# Source from ~/.zshrc. Provides: cc, ccc, ccr, ccf, cc-yolo, cc-edit,
# cc-plan, cc-read, cc-opus, cc-sonnet, cc-haiku, cc-q, cc-pipe,
# cc-review, cc-review-branch, cc-explain, cc-msg, cc-deep, cc-fast,
# cc-debug, cc-budget, cc-vm, cc-nobash, cc-nonet, cc-jail,
# cc-sbox, cc-sbox-edit, cc-sbox-deep, cc-sbox-test,
# cc-mono, cc-wt, cc-pr, cc-help
#
# Note: `cc` shadows the system C compiler (cc -> clang on macOS).
# If you need the C compiler, use `clang` or `gcc` directly,
# or rename the cc() function below to something like `cl`.

# ─── Core Session ────────────────────────────────────────────────────────────

cc() {
  claude --chrome "$@"
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

cc-vm() {
  # Full autonomy inside a real sandbox (Docker/VM). No permission prompts.
  # Intended for environments where the container IS the safety boundary.
  claude --dangerously-skip-permissions --model "${CC_SANDBOX_MODEL:-sonnet}" "$@"
}

cc-sandbox() {
  # Deprecated: renamed to cc-vm. Use cc-sbox for kernel sandbox.
  echo "Note: cc-sandbox is now cc-vm (Docker/VM use). For kernel sandbox, use cc-sbox." >&2
  cc-vm "$@"
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

# ─── Kernel Sandbox (macOS Seatbelt) ─────────────────────────────────────────

_cc_sandbox_profile() {
  echo "${HOME}/.claude/scripts/claude-sandbox.sb"
}

_cc_resolve_project_dir() {
  # Priority: CC_SANDBOX_DIR env var > worktree > git root > PWD
  if [ -n "${CC_SANDBOX_DIR:-}" ]; then
    (cd "$CC_SANDBOX_DIR" && pwd)
    return
  fi

  # Walk up looking for .worktree.json (wt.sh managed worktree)
  local dir="$PWD"
  while [ "$dir" != "/" ]; do
    if [ -f "$dir/.worktree.json" ]; then
      echo "$dir"
      return
    fi
    dir="$(dirname "$dir")"
  done

  # Fall back to git root
  local git_root
  git_root="$(git rev-parse --show-toplevel 2>/dev/null)"
  if [ -n "$git_root" ]; then
    echo "$git_root"
    return
  fi

  # Last resort: current directory
  echo "$PWD"
}

_cc_sandbox_exec() {
  local profile project_dir claude_home tmpdir_real
  profile="$(_cc_sandbox_profile)"

  if [ ! -f "$profile" ]; then
    echo "Error: Seatbelt profile not found at $profile" >&2
    return 1
  fi

  if ! command -v sandbox-exec &>/dev/null; then
    echo "Error: sandbox-exec not found. Kernel sandbox requires macOS." >&2
    return 1
  fi

  project_dir="$(_cc_resolve_project_dir)"
  claude_home="${HOME}/.claude"
  tmpdir_real="$(cd "${TMPDIR:-/tmp}" && pwd -P)"

  echo "┌─────────────────────────────────────────────────────────"
  echo "│ Kernel Sandbox Active"
  echo "│ Writes allowed:  $project_dir"
  echo "│                  $claude_home"
  echo "│                  $tmpdir_real"
  echo "│ Writes blocked:  everywhere else (kernel-enforced)"
  echo "└─────────────────────────────────────────────────────────"

  sandbox-exec -f "$profile" \
    -D "PROJECT_DIR=$project_dir" \
    -D "CLAUDE_HOME=$claude_home" \
    -D "TMPDIR_REAL=$tmpdir_real" \
    claude "$@"
}

cc-sbox() {
  # Yolo mode inside kernel sandbox — full autonomy within project boundary
  _cc_sandbox_exec --dangerously-skip-permissions "$@"
}

cc-sbox-edit() {
  # acceptEdits mode inside kernel sandbox
  _cc_sandbox_exec --permission-mode acceptEdits "$@"
}

cc-sbox-deep() {
  # Opus + yolo + continue inside kernel sandbox
  _cc_sandbox_exec --dangerously-skip-permissions --model opus --continue "$@"
}

cc-sbox-test() {
  # Verify sandbox boundaries — attempts writes in/out of boundary
  local project_dir claude_home tmpdir_real profile
  profile="$(_cc_sandbox_profile)"

  if [ ! -f "$profile" ]; then
    echo "Error: Seatbelt profile not found at $profile" >&2
    return 1
  fi

  if ! command -v sandbox-exec &>/dev/null; then
    echo "Error: sandbox-exec not found. Kernel sandbox requires macOS." >&2
    return 1
  fi

  project_dir="$(_cc_resolve_project_dir)"
  claude_home="${HOME}/.claude"
  tmpdir_real="$(cd "${TMPDIR:-/tmp}" && pwd -P)"

  echo "Testing kernel sandbox boundaries..."
  echo "  Project dir: $project_dir"
  echo "  Claude home: $claude_home"
  echo "  Temp dir:    $tmpdir_real"
  echo ""

  local pass=0 fail=0
  local test_file

  # Test 1: Write inside project dir (should succeed)
  test_file="$project_dir/.sandbox-test-$$"
  if sandbox-exec -f "$profile" \
    -D "PROJECT_DIR=$project_dir" \
    -D "CLAUDE_HOME=$claude_home" \
    -D "TMPDIR_REAL=$tmpdir_real" \
    bash -c "echo test > '$test_file'" 2>/dev/null; then
    echo "  PASS  Write inside project dir"
    rm -f "$test_file"
    ((pass++))
  else
    echo "  FAIL  Write inside project dir (should have succeeded)"
    ((fail++))
  fi

  # Test 2: Write inside ~/.claude (should succeed)
  test_file="$claude_home/.sandbox-test-$$"
  if sandbox-exec -f "$profile" \
    -D "PROJECT_DIR=$project_dir" \
    -D "CLAUDE_HOME=$claude_home" \
    -D "TMPDIR_REAL=$tmpdir_real" \
    bash -c "echo test > '$test_file'" 2>/dev/null; then
    echo "  PASS  Write inside ~/.claude"
    rm -f "$test_file"
    ((pass++))
  else
    echo "  FAIL  Write inside ~/.claude (should have succeeded)"
    ((fail++))
  fi

  # Test 3: Write inside TMPDIR (should succeed)
  test_file="$tmpdir_real/sandbox-test-$$"
  if sandbox-exec -f "$profile" \
    -D "PROJECT_DIR=$project_dir" \
    -D "CLAUDE_HOME=$claude_home" \
    -D "TMPDIR_REAL=$tmpdir_real" \
    bash -c "echo test > '$test_file'" 2>/dev/null; then
    echo "  PASS  Write inside TMPDIR"
    rm -f "$test_file"
    ((pass++))
  else
    echo "  FAIL  Write inside TMPDIR (should have succeeded)"
    ((fail++))
  fi

  # Test 4: Write to HOME (outside boundary — should fail)
  test_file="${HOME}/.sandbox-test-$$"
  if sandbox-exec -f "$profile" \
    -D "PROJECT_DIR=$project_dir" \
    -D "CLAUDE_HOME=$claude_home" \
    -D "TMPDIR_REAL=$tmpdir_real" \
    bash -c "echo test > '$test_file'" 2>/dev/null; then
    echo "  FAIL  Write to HOME (should have been blocked)"
    rm -f "$test_file"
    ((fail++))
  else
    echo "  PASS  Write to HOME blocked"
    ((pass++))
  fi

  # Test 5: Write to /tmp directly (outside TMPDIR — should fail if TMPDIR != /tmp)
  if [ "$tmpdir_real" != "/tmp" ] && [ "$tmpdir_real" != "/private/tmp" ]; then
    test_file="/tmp/sandbox-test-$$"
    if sandbox-exec -f "$profile" \
      -D "PROJECT_DIR=$project_dir" \
      -D "CLAUDE_HOME=$claude_home" \
      -D "TMPDIR_REAL=$tmpdir_real" \
      bash -c "echo test > '$test_file'" 2>/dev/null; then
      echo "  FAIL  Write to /tmp (should have been blocked)"
      rm -f "$test_file"
      ((fail++))
    else
      echo "  PASS  Write to /tmp blocked"
      ((pass++))
    fi
  fi

  echo ""
  echo "Results: $pass passed, $fail failed"
  [ "$fail" -eq 0 ] && return 0 || return 1
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
  cc [args]                 claude --chrome (passthrough, shadows system cc compiler)
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

Kernel Sandbox (macOS Seatbelt):
  cc-sbox [args]            Yolo inside kernel sandbox — writes scoped to project
  cc-sbox-edit [args]       acceptEdits inside kernel sandbox
  cc-sbox-deep [args]       Opus + yolo + continue inside kernel sandbox
  cc-sbox-test              Verify sandbox boundaries (run in project dir)
                              Set CC_SANDBOX_DIR=/path to override project detection

Sandbox Modes:                    (least restricted → most restricted)
  cc-vm [args]              Full autonomy, for use inside Docker/VM
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
  All functions pass through args to claude (cc includes --chrome), so combine:
    cc-opus --continue                     Opus + continue + chrome
    cc-yolo --model opus                   Yolo + opus + chrome
    cc-edit --continue --model haiku       Accept edits + continue + haiku + chrome

  cc-help                   Show this help message
HELP
}
