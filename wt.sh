#!/usr/bin/env bash
# wt.sh — Git Worktree Management for Claude Code
# Source from ~/.zshrc. Provides: wt (list, merge, rebase, cleanup, done, prune, cd, help)
# Legacy aliases: wt-list, wt-merge, wt-rebase, wt-cleanup, wt-done, wt-prune, wtc, wt-help
#
# Requires: jq, git

# ─── Dependency Check ────────────────────────────────────────────────────────

if ! command -v jq &>/dev/null; then
  echo "wt.sh: Warning — jq is required but not installed. Install with: brew install jq" >&2
fi

# ─── Helpers ─────────────────────────────────────────────────────────────────

_wt_ensure_git_root() {
  # Resolves to the main repo root, even when called from inside a worktree
  if ! git rev-parse --is-inside-work-tree &>/dev/null; then
    echo "Error: Not inside a git repository." >&2
    return 1
  fi
  local toplevel common_dir main_toplevel
  toplevel="$(git rev-parse --show-toplevel)"
  common_dir="$(cd "$toplevel" && cd "$(git rev-parse --git-common-dir)" && pwd)"
  # common_dir is now the .git dir (absolute). Parent is the main repo root.
  main_toplevel="$(dirname "$common_dir")"
  # Verify it's actually a git repo root (handles bare repos gracefully)
  git -C "$main_toplevel" rev-parse --show-toplevel 2>/dev/null || echo "$toplevel"
}

_wt_check_jq() {
  if ! command -v jq &>/dev/null; then
    echo "Error: jq is required. Install with: brew install jq" >&2
    return 1
  fi
}

_wt_ensure_gitignore() {
  local repo_root="$1"
  if ! git -C "$repo_root" check-ignore -q .worktrees 2>/dev/null; then
    if [ -f "$repo_root/.gitignore" ]; then
      echo "" >> "$repo_root/.gitignore"
      echo "# Git worktrees managed by wt.sh" >> "$repo_root/.gitignore"
      echo ".worktrees/" >> "$repo_root/.gitignore"
    else
      echo "# Git worktrees managed by wt.sh" > "$repo_root/.gitignore"
      echo ".worktrees/" >> "$repo_root/.gitignore"
    fi
    echo "Added .worktrees/ to .gitignore"
  fi
}

_wt_prompt() {
  local prompt_text="$1"
  printf "%s " "$prompt_text"
  read -r REPLY
}

# ─── Worktree Context Injection ──────────────────────────────────────────────

_wt_inject_worktree_context() {
  local claude_md="$1" project="$2" branch="$3" base="$4" worktree_path="$5" repo_root="$6"

  # Prevent double-injection
  if [ -f "$claude_md" ] && grep -q "<!-- WORKTREE-CONTEXT-INJECTED -->" "$claude_md"; then
    return 0
  fi

  # Append context (cat >> creates file if it doesn't exist)
  cat >> "$claude_md" <<WTCONTEXT

<!-- WORKTREE-CONTEXT-INJECTED -->
## Worktree Context -- READ THIS FIRST

**You are in a worktree.** This is an isolated workspace.

| Field | Value |
|-------|-------|
| Project | \`${project}\` |
| Branch | \`${branch}\` |
| Base branch | \`${base}\` |
| Worktree path | \`${worktree_path}\` |
| Main repo | \`${repo_root}\` |

### Hard Rules
1. **Stay in this directory.** Do not \`cd\` to the main repo or other worktrees.
2. **Do not switch branches.** Never \`git checkout\` or \`git switch\`.
3. **Do not read/modify files in other worktrees.** Those are other Claude instances' workspaces.
4. **PRs target \`${base}\`.**
5. **Do not create new branches** without explicit user instruction.
6. **Verify at session start:** \`pwd && git branch --show-current\`
7. **Do not modify this section.** It is auto-generated.

### Lifecycle
Tell the user to run these from the **main repo terminal** (not from within this worktree):
- \`wt rebase ${branch}\` — rebase onto latest \`${base}\`
- \`wt merge ${branch}\` — merge into \`${base}\` and optionally clean up
- \`wt done ${branch}\` — remove worktree, delete branch, checkout \`${base}\`
WTCONTEXT
}

# ─── Main CLAUDE.md Map Update ───────────────────────────────────────────────

_wt_update_main_claude_md() {
  local repo_root="$1"
  local claude_md="$repo_root/CLAUDE.md"

  # Silently skip if no CLAUDE.md or no markers
  [ ! -f "$claude_md" ] && return 0
  grep -q "<!-- WORKTREE-MAP-START -->" "$claude_md" || return 0

  # Build worktree table to a temp file (avoids awk -v escaping issues)
  local table_file
  table_file="$(mktemp)"
  trap 'rm -f "$table_file"' RETURN

  echo "| Branch | Base | Path | Status |" > "$table_file"
  echo "|--------|------|------|--------|" >> "$table_file"

  local worktrees_dir="$repo_root/.worktrees"
  local has_worktrees=false

  local meta wt_branch wt_base wt_name wt_status
  if [ -d "$worktrees_dir" ]; then
    while IFS= read -r entry; do
      [ -z "$entry" ] && continue
      [ ! -d "$entry" ] && continue
      meta="$entry/.worktree.json"
      [ ! -f "$meta" ] && continue
      has_worktrees=true

      wt_branch="$(jq -r '.branch // "-"' "$meta" 2>/dev/null)"
      wt_base="$(jq -r '.base_branch // "-"' "$meta" 2>/dev/null)"
      wt_name="$(basename "$entry")"
      wt_status="$(jq -r '.status // "active"' "$meta" 2>/dev/null)"

      echo "| \`${wt_branch}\` | \`${wt_base}\` | \`.worktrees/${wt_name}\` | ${wt_status} |" >> "$table_file"
    done < <(find "$worktrees_dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
  fi

  if [ "$has_worktrees" = false ]; then
    echo "| _(none)_ | | | |" >> "$table_file"
  fi

  # Replace content between markers using awk (reads table from file, atomic via temp+mv)
  local tmp
  tmp="$(mktemp)"
  awk -v tablefile="$table_file" '
    /<!-- WORKTREE-MAP-START -->/ {
      print
      while ((getline line < tablefile) > 0) print line
      close(tablefile)
      skip=1
      next
    }
    /<!-- WORKTREE-MAP-END -->/ {
      skip=0
      print
      next
    }
    !skip { print }
  ' "$claude_md" > "$tmp"
  mv "$tmp" "$claude_md" || { rm -f "$table_file" "$tmp"; return 1; }
  rm -f "$table_file"
}

# ─── Hookify Rule Generation ────────────────────────────────────────────────

_wt_generate_hookify_rule() {
  local worktree_path="$1"
  local rule_file="$worktree_path/.claude/hookify.worktree-boundary.local.md"

  mkdir -p "$worktree_path/.claude"

  cat > "$rule_file" <<HOOKIFY
---
name: worktree-boundary-guard
enabled: true
event: file
conditions:
  - field: file_path
    operator: not_contains
    pattern: "${worktree_path}"
action: warn
---
You are editing a file outside your worktree boundary (\`${worktree_path}\`).
You should only edit files within this worktree. If you need to edit files elsewhere, ask the user first.
HOOKIFY
}

# ─── Lockfile Management ────────────────────────────────────────────────────

_wt_acquire_lock() {
  local lockdir="$1"
  local max_wait="${2:-10}"
  local waited=0
  local lock_pid

  while ! mkdir "$lockdir" 2>/dev/null; do
    lock_pid="$(cat "$lockdir/pid" 2>/dev/null)"
    if [ -z "$lock_pid" ] || ! kill -0 "$lock_pid" 2>/dev/null; then
      # Lock dir exists but no pid file or process is gone — stale lock
      echo "Removing stale lock${lock_pid:+ (PID $lock_pid no longer running)}"
      rm -rf "$lockdir"
      continue
    fi
    if [ "$waited" -ge "$max_wait" ]; then
      echo "Error: Could not acquire lock after ${max_wait}s (held by PID $lock_pid)" >&2
      return 1
    fi
    [ "$waited" -eq 0 ] && echo "Waiting for lock (held by PID $lock_pid)..."
    sleep 1
    waited=$((waited + 1))
  done

  echo $$ > "$lockdir/pid"
}

_wt_release_lock() {
  rm -rf "$1"
}

# ─── Process Cleanup ─────────────────────────────────────────────────────────

_wt_kill_procs() {
  local worktree_path="$1"
  local name="$2"
  local force="$3"  # "true" = skip prompts, auto-kill

  # Try _dev_stop first (port-based, clean shutdown) — only in interactive mode
  if [ "$force" != "true" ] && type _dev_stop &>/dev/null; then
    _dev_stop "$name" 2>/dev/null || true
  fi

  # Find processes whose CWD is under the worktree path (catches nested dirs)
  # Falls back to lsof +d if the CWD approach finds nothing
  local pids="" pid cwd comm
  while IFS= read -r pid; do
    [ -z "$pid" ] && continue
    cwd="$(lsof -p "$pid" -d cwd -Fn 2>/dev/null | grep '^n' | cut -c2-)" || continue
    if [[ "$cwd/" == "$worktree_path/"* ]]; then
      pids="$pids $pid"
    fi
  done < <(ps -eo pid= -o comm= 2>/dev/null | awk '{print $1}')

  # Also catch processes with open files directly in the worktree root
  local lsof_pids
  lsof_pids="$(timeout 5 lsof +d "$worktree_path" -t 2>/dev/null | sort -u)" || true
  if [ -n "$lsof_pids" ]; then
    pids="$pids $lsof_pids"
  fi

  # Deduplicate
  pids="$(echo "$pids" | tr ' ' '\n' | sort -un | tr '\n' ' ')"
  pids="${pids## }"
  pids="${pids%% }"

  if [ -z "$pids" ]; then
    return 0
  fi

  # Separate Claude Code / agent processes from everything else
  local cc_pids="" other_pids=""
  local has_cc=false
  for pid in $pids; do
    comm="$(ps -p "$pid" -o comm= 2>/dev/null)" || continue
    # Claude Code runs as node with "claude" in args, or as the claude binary
    if [[ "$comm" == *claude* ]] || ps -p "$pid" -o args= 2>/dev/null | grep -q "claude"; then
      cc_pids="$cc_pids $pid"
      has_cc=true
    else
      other_pids="$other_pids $pid"
    fi
  done

  # Auto-kill non-Claude processes
  for pid in $other_pids; do
    comm="$(ps -p "$pid" -o comm= 2>/dev/null)" || continue
    if [ "$force" = "true" ]; then
      kill "$pid" 2>/dev/null && echo "  Killed $comm (PID $pid)" || true
    else
      _wt_prompt "  Kill $comm (PID $pid)? [y/N]"
      if [[ "$REPLY" =~ ^[Yy]$ ]]; then
        kill "$pid" 2>/dev/null && echo "  Killed." || echo "  Already exited."
      else
        echo "  Skipped."
      fi
    fi
  done

  # Handle Claude Code sessions — prompt unless force mode
  if [ "$has_cc" = true ]; then
    if [ "$force" = "true" ]; then
      for pid in $cc_pids; do
        kill "$pid" 2>/dev/null && echo "  Killed Claude Code (PID $pid)" || true
      done
    else
      echo ""
      echo "⚠  Active Claude Code sessions in worktree '$name':"
      for pid in $cc_pids; do
        echo "  PID $pid: $(ps -p "$pid" -o args= 2>/dev/null | head -c 80)"
      done
      echo ""
      _wt_prompt "Kill Claude Code sessions? They may have in-flight work. [y/N]"
      if [[ "$REPLY" =~ ^[Yy]$ ]]; then
        for pid in $cc_pids; do
          kill "$pid" 2>/dev/null && echo "  Killed PID $pid" || true
        done
      else
        echo "  Skipped. Close them manually, then re-run."
        return 1
      fi
    fi
  fi

  return 0
}

# ─── Project Setup ───────────────────────────────────────────────────────────

_wt_run_project_setup() {
  local worktree_path="$1"

  if [ -f "$worktree_path/package.json" ]; then
    if [ -f "$worktree_path/bun.lock" ] || [ -f "$worktree_path/bun.lockb" ]; then
      echo "Running bun install..."
      (cd "$worktree_path" && bun install 2>&1) || echo "Warning: bun install failed"
    elif [ -f "$worktree_path/package-lock.json" ]; then
      echo "Running npm install..."
      (cd "$worktree_path" && npm install 2>&1) || echo "Warning: npm install failed"
    elif [ -f "$worktree_path/yarn.lock" ]; then
      echo "Running yarn install..."
      (cd "$worktree_path" && yarn install 2>&1) || echo "Warning: yarn install failed"
    elif [ -f "$worktree_path/pnpm-lock.yaml" ]; then
      echo "Running pnpm install..."
      (cd "$worktree_path" && pnpm install 2>&1) || echo "Warning: pnpm install failed"
    else
      echo "Running npm install (default)..."
      (cd "$worktree_path" && npm install 2>&1) || echo "Warning: npm install failed"
    fi
  elif [ -f "$worktree_path/Cargo.toml" ]; then
    echo "Running cargo build..."
    (cd "$worktree_path" && cargo build 2>&1) || echo "Warning: cargo build failed"
  elif [ -f "$worktree_path/requirements.txt" ]; then
    echo "Running pip install..."
    (cd "$worktree_path" && pip install -r requirements.txt 2>&1) || echo "Warning: pip install failed"
  elif [ -f "$worktree_path/pyproject.toml" ]; then
    if [ -f "$worktree_path/uv.lock" ]; then
      echo "Running uv sync..."
      (cd "$worktree_path" && uv sync 2>&1) || echo "Warning: uv sync failed"
    elif [ -f "$worktree_path/poetry.lock" ]; then
      echo "Running poetry install..."
      (cd "$worktree_path" && poetry install 2>&1) || echo "Warning: poetry install failed"
    fi
  elif [ -f "$worktree_path/go.mod" ]; then
    echo "Running go mod download..."
    (cd "$worktree_path" && go mod download 2>&1) || echo "Warning: go mod download failed"
  fi
}

# ─── Main Functions ──────────────────────────────────────────────────────────

_wt_create() {
  local name="$1"
  local base="${2:-HEAD}"

  if [ -z "$name" ]; then
    echo "Usage: wt <name> [base-branch]"
    echo "  Creates a git worktree in .worktrees/<name>"
    echo ""
    echo "Subcommands:"
    echo "  wt list              List worktrees with status"
    echo "  wt merge [name]      Merge worktree into base branch"
    echo "  wt rebase [name]     Rebase worktree onto latest base branch"
    echo "  wt cleanup <name>    Remove a worktree"
    echo "  wt done [name]       Post-merge: cleanup + checkout base + pull"
    echo "  wt prune [--stale|--all]  Batch-remove worktrees"
    echo "  wt cd <name>         cd into an existing worktree"
    echo "  wt help              Show full help"
    return 1
  fi

  _wt_check_jq || return 1

  # Validate branch name
  if ! git check-ref-format --branch "$name" &>/dev/null; then
    echo "Error: '$name' is not a valid branch name." >&2
    return 1
  fi

  # Get main repo root
  local repo_root
  repo_root="$(_wt_ensure_git_root)" || return 1

  # Prevent running from inside a worktree
  local current_toplevel
  current_toplevel="$(git rev-parse --show-toplevel)"
  if [ "$current_toplevel" != "$repo_root" ]; then
    echo "Error: You are inside a worktree. Run wt from the main repo: $repo_root" >&2
    return 1
  fi

  # Ensure .worktrees is gitignored
  _wt_ensure_gitignore "$repo_root"

  local worktree_path="$repo_root/.worktrees/$name"

  if [ -d "$worktree_path" ]; then
    # Check if it's a healthy worktree or a broken leftover
    if [ -f "$worktree_path/.worktree.json" ] && { [ -d "$worktree_path/.git" ] || [ -f "$worktree_path/.git" ]; }; then
      echo "Worktree '$name' already exists at $worktree_path"
      echo "  Branch: $(git -C "$worktree_path" branch --show-current 2>/dev/null || echo "unknown")"
      echo ""
      _wt_prompt "cd into it? [Y/n/r] (r = remove and recreate)"
      case "$REPLY" in
        [Rr])
          echo "Removing existing worktree..."
          git -C "$repo_root" worktree remove "$worktree_path" --force 2>/dev/null || {
            rm -rf "$worktree_path"
            git -C "$repo_root" worktree prune
          }
          ;; # fall through to create
        [Nn])
          return 0
          ;;
        *)
          cd "$worktree_path" || return 1
          echo "Now in: $(pwd)"
          echo "Branch: $(git branch --show-current)"
          return 0
          ;;
      esac
    else
      # Broken leftover — directory exists but not a valid worktree
      echo "Worktree '$name' exists but appears broken (missing .git or metadata)."
      _wt_prompt "Remove and recreate? [y/N]"
      if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
        return 0
      fi
      echo "Removing broken worktree..."
      git -C "$repo_root" worktree remove "$worktree_path" --force 2>/dev/null || {
        rm -rf "$worktree_path"
        git -C "$repo_root" worktree prune
      }
      # fall through to create
    fi
  fi

  # Resolve base to a branch name for metadata
  local base_branch
  if [ "$base" = "HEAD" ]; then
    base_branch="$(git -C "$repo_root" branch --show-current)"
    [ -z "$base_branch" ] && base_branch="$(git -C "$repo_root" rev-parse --short HEAD)"
  else
    base_branch="$base"
  fi

  local project
  project="$(basename "$repo_root")"

  # Create parent directory (handles nested branch names like feature/auth)
  mkdir -p "$(dirname "$worktree_path")"

  # Create the worktree
  echo "Creating worktree '$name' from '$base_branch'..."
  if git -C "$repo_root" show-ref --verify --quiet "refs/heads/$name" 2>/dev/null; then
    git -C "$repo_root" worktree add "$worktree_path" "$name" || return 1
  else
    git -C "$repo_root" worktree add -b "$name" "$worktree_path" "$base" || return 1
  fi

  # Write metadata (atomic via temp+mv)
  local now tmp_meta
  now="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  tmp_meta="$(mktemp)"
  jq -n \
    --arg branch "$name" \
    --arg base_branch "$base_branch" \
    --arg created "$now" \
    --arg main_repo "$repo_root" \
    --arg status "active" \
    '{branch: $branch, base_branch: $base_branch, created: $created, main_repo: $main_repo, status: $status}' \
    > "$tmp_meta"
  mv "$tmp_meta" "$worktree_path/.worktree.json"
  echo "  Created .worktree.json"

  # Propagate .claude config
  if [ -d "$repo_root/.claude" ]; then
    mkdir -p "$worktree_path/.claude"

    # Symlink shared directories (absolute targets)
    for dir in hooks commands templates skills agents; do
      if [ -d "$repo_root/.claude/$dir" ]; then
        ln -sfn "$repo_root/.claude/$dir" "$worktree_path/.claude/$dir"
        echo "  Symlinked .claude/$dir"
      fi
    done

    # Copy config files (may diverge per worktree)
    for file in settings.json settings.local.json; do
      if [ -f "$repo_root/.claude/$file" ]; then
        cp "$repo_root/.claude/$file" "$worktree_path/.claude/$file"
        echo "  Copied .claude/$file"
      fi
    done
  fi

  # Symlink env files from main repo (gitignored files needed for dev servers)
  for envfile in .env .env.local .env.development .env.development.local; do
    if [ -f "$repo_root/$envfile" ]; then
      ln -sfn "$repo_root/$envfile" "$worktree_path/$envfile"
      echo "  Symlinked $envfile"
    fi
  done

  # Inject worktree context into CLAUDE.md (git already provides tracked version)
  _wt_inject_worktree_context "$worktree_path/CLAUDE.md" "$project" "$name" "$base_branch" "$worktree_path" "$repo_root"
  echo "  Injected worktree context into CLAUDE.md"

  # Generate hookify boundary guard
  _wt_generate_hookify_rule "$worktree_path"
  echo "  Generated hookify boundary guard"

  # Update main repo CLAUDE.md worktree map
  _wt_update_main_claude_md "$repo_root"

  # Run project setup
  _wt_run_project_setup "$worktree_path"

  echo ""
  echo "Worktree '$name' ready at: $worktree_path"

  # cd into the new worktree so the user is immediately working there
  cd "$worktree_path" || return 1
  echo "Now in: $(pwd)"
  echo "Branch: $(git branch --show-current)"
}

_wt_list() {
  local repo_root
  repo_root="$(_wt_ensure_git_root)" || return 1

  local worktrees_dir="$repo_root/.worktrees"

  if [ ! -d "$worktrees_dir" ]; then
    echo "No .worktrees/ directory found."
    echo ""
    echo "Git worktree list:"
    git -C "$repo_root" worktree list
    return 0
  fi

  echo ""
  printf "%-25s %-20s %-15s %-20s %s\n" "NAME" "BRANCH" "BASE" "LAST COMMIT" "STATUS"
  printf "%-25s %-20s %-15s %-20s %s\n" "----" "------" "----" "-----------" "------"

  local has_entries=false
  local name meta branch base wt_status last_commit commit_epoch now_epoch age_days

  while IFS= read -r entry; do
    [ -z "$entry" ] && continue
    [ ! -d "$entry" ] && continue
    has_entries=true

    name="$(basename "$entry")"
    meta="$entry/.worktree.json"

    branch="-"
    base="-"
    wt_status="unknown"
    if [ -f "$meta" ] && command -v jq &>/dev/null; then
      branch="$(jq -r '.branch // "-"' "$meta" 2>/dev/null)"
      base="$(jq -r '.base_branch // "-"' "$meta" 2>/dev/null)"
      wt_status="$(jq -r '.status // "unknown"' "$meta" 2>/dev/null)"
    fi

    # Get last commit age
    last_commit="-"
    if [ -d "$entry/.git" ] || [ -f "$entry/.git" ]; then
      last_commit="$(git -C "$entry" log -1 --format='%cr' 2>/dev/null || echo "-")"

      # Staleness detection (>7 days since last commit)
      commit_epoch="$(git -C "$entry" log -1 --format='%ct' 2>/dev/null || echo "0")"
      now_epoch="$(date +%s)"
      age_days=$(( (now_epoch - commit_epoch) / 86400 ))
      if [ "$age_days" -gt 7 ]; then
        wt_status="stale"
      fi
    elif [ ! -f "$meta" ]; then
      # No .git and no metadata — partially created worktree from failed git worktree add
      wt_status="broken"
    fi

    printf "%-25s %-20s %-15s %-20s %s\n" "$name" "$branch" "$base" "$last_commit" "$wt_status"
  done < <(find "$worktrees_dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)

  if [ "$has_entries" = false ]; then
    echo "(no managed worktrees)"
  fi

  echo ""
  echo "Git worktree list:"
  git -C "$repo_root" worktree list
  echo ""
}

_wt_merge() {
  _wt_check_jq || return 1

  local name="$1"
  local repo_root meta worktree_path

  repo_root="$(_wt_ensure_git_root)" || return 1

  if [ -n "$name" ]; then
    # Name provided — look up worktree by name
    worktree_path="$repo_root/.worktrees/$name"
    meta="$worktree_path/.worktree.json"
  else
    # Auto-detect from current directory
    worktree_path="$(pwd)"
    meta="$worktree_path/.worktree.json"
  fi

  if [ ! -f "$meta" ]; then
    echo "Error: Not in a managed worktree (no .worktree.json found)." >&2
    echo "Usage: wt merge [name]  (run from worktree or pass name)" >&2
    return 1
  fi

  local branch base_branch main_repo
  branch="$(jq -r '.branch' "$meta")"
  base_branch="$(jq -r '.base_branch' "$meta")"
  main_repo="$(jq -r '.main_repo' "$meta")"
  name="${name:-$branch}"

  # Acquire merge lock (atomic mkdir-based with stale detection)
  local lockfile="$main_repo/.worktrees/.merge.lock"
  _wt_acquire_lock "$lockfile" 10 || return 1

  echo "Merging worktree '$name' (branch: $branch) into '$base_branch'"
  echo ""

  # Check for uncommitted changes
  if ! git -C "$worktree_path" diff --quiet 2>/dev/null || ! git -C "$worktree_path" diff --cached --quiet 2>/dev/null; then
    echo "Warning: Uncommitted changes in this worktree:"
    git -C "$worktree_path" status --short
    echo ""
    _wt_prompt "Continue? Uncommitted changes will NOT be merged. [y/N]"
    if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
      echo "Aborted."
      _wt_release_lock "$lockfile"
      return 1
    fi
  fi

  # Show diff summary
  echo "Changes to merge:"
  echo "---"
  local commits
  commits="$(git -C "$main_repo" log "${base_branch}..${branch}" --oneline 2>/dev/null)"
  if [ -z "$commits" ]; then
    echo "  No new commits to merge."
    _wt_prompt "Continue with cleanup anyway? [y/N]"
    if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
      echo "Aborted."
      _wt_release_lock "$lockfile"
      return 0
    fi
  else
    echo "$commits"
    echo ""
    git -C "$main_repo" diff --stat "${base_branch}..${branch}" 2>/dev/null
  fi
  echo ""

  _wt_prompt "Proceed with merge into '$base_branch'? [y/N]"
  if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    _wt_release_lock "$lockfile"
    return 0
  fi

  # If we're inside the worktree being removed, move out
  if [[ "$(pwd)/" == "$worktree_path/"* ]]; then
    cd "$main_repo" || return 1
  fi

  # Checkout base branch in main repo (explicit target from metadata)
  git -C "$main_repo" checkout "$base_branch" || {
    echo "Error: Could not checkout '$base_branch' in main repo." >&2
    _wt_release_lock "$lockfile"
    return 1
  }

  # Merge
  if git -C "$main_repo" merge "$branch"; then
    echo ""
    echo "Merged '$branch' into '$base_branch' successfully."
  else
    echo ""
    echo "Error: Merge failed. Resolve conflicts in $main_repo, then run:" >&2
    echo "  wt cleanup $name" >&2
    _wt_release_lock "$lockfile"
    return 1
  fi

  # Prompt for cleanup
  echo ""
  _wt_prompt "Clean up worktree '$name'? [Y/n]"
  if [[ ! "$REPLY" =~ ^[Nn]$ ]]; then
    # Remove worktree using git -C (no cd)
    git -C "$main_repo" worktree remove "$worktree_path" --force 2>/dev/null || {
      rm -rf "$worktree_path"
      git -C "$main_repo" worktree prune
    }
    echo "Removed worktree directory."

    # Delete branch
    _wt_prompt "Delete branch '$branch'? [Y/n]"
    if [[ ! "$REPLY" =~ ^[Nn]$ ]]; then
      git -C "$main_repo" branch -d "$branch" 2>/dev/null || git -C "$main_repo" branch -D "$branch"
      echo "Deleted branch '$branch'."
    fi

    # Update main CLAUDE.md map
    _wt_update_main_claude_md "$main_repo"
  fi

  _wt_release_lock "$lockfile"

  echo ""
  echo "Done. Branch '$base_branch' in $main_repo"
}

_wt_cleanup() {
  local name="$1"

  if [ -z "$name" ]; then
    # Auto-detect from current directory
    if [ -f ".worktree.json" ]; then
      name="$(jq -r '.branch' "$PWD/.worktree.json" 2>/dev/null)"
    fi
    if [ -z "$name" ]; then
      echo "Usage: wt cleanup <name>" >&2
      return 1
    fi
  fi

  local repo_root
  repo_root="$(_wt_ensure_git_root)" || return 1

  local worktree_path="$repo_root/.worktrees/$name"

  if [ ! -d "$worktree_path" ]; then
    echo "Error: Worktree '$name' not found at $worktree_path" >&2
    return 1
  fi

  # Check for uncommitted changes (using git -C, no cd)
  local has_changes=false
  if ! git -C "$worktree_path" diff --quiet 2>/dev/null || ! git -C "$worktree_path" diff --cached --quiet 2>/dev/null; then
    has_changes=true
    echo "Warning: Worktree '$name' has uncommitted changes:"
    git -C "$worktree_path" status --short
    echo ""
  fi

  if [ "$has_changes" = true ]; then
    _wt_prompt "Remove worktree '$name' with uncommitted changes? This is irreversible. [y/N]"
  else
    _wt_prompt "Remove worktree '$name'? [y/N]"
  fi

  if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    return 0
  fi

  # Get branch name before removing
  local branch=""
  if [ -f "$worktree_path/.worktree.json" ] && command -v jq &>/dev/null; then
    branch="$(jq -r '.branch // ""' "$worktree_path/.worktree.json")"
  fi

  # Kill any processes running inside the worktree
  _wt_kill_procs "$worktree_path" "$name" "false" || return 1

  # If we're inside the worktree being removed, move out
  if [[ "$(pwd)/" == "$worktree_path/"* ]]; then
    cd "$repo_root" || true
  fi

  # Remove worktree (using git -C, no cd)
  git -C "$repo_root" worktree remove "$worktree_path" --force 2>/dev/null || {
    rm -rf "$worktree_path"
    git -C "$repo_root" worktree prune
  }
  echo "Removed worktree '$name'."

  # Optionally delete branch
  if [ -n "$branch" ]; then
    _wt_prompt "Also delete branch '$branch'? [y/N]"
    if [[ "$REPLY" =~ ^[Yy]$ ]]; then
      git -C "$repo_root" branch -d "$branch" 2>/dev/null || git -C "$repo_root" branch -D "$branch"
      echo "Deleted branch '$branch'."
    fi
  fi

  # Update main CLAUDE.md map
  _wt_update_main_claude_md "$repo_root"
}

_wtc() {
  local name="$1"

  if [ -z "$name" ]; then
    echo "Usage: wt cd <name>" >&2
    echo "  cd into an existing worktree" >&2
    return 1
  fi

  local repo_root
  repo_root="$(_wt_ensure_git_root)" || return 1

  local worktree_path="$repo_root/.worktrees/$name"

  if [ ! -d "$worktree_path" ]; then
    echo "Error: Worktree '$name' not found at $worktree_path" >&2
    echo "Available worktrees:"
    ls -1 "$repo_root/.worktrees/" 2>/dev/null || echo "  (none)"
    return 1
  fi

  cd "$worktree_path" || return 1
  echo "Now in worktree '$name' at $worktree_path"
  echo "Branch: $(git branch --show-current)"
}

_wt_help() {
  cat <<'HELP'
Git Worktree Management for Claude Code
========================================

Usage:
  wt <name> [base]       Create worktree in .worktrees/<name>, cd into it
                          base defaults to current branch (HEAD)
  wt -- <name> [base]     Force create (bypass subcommand matching)

Subcommands:
  wt list                List all worktrees with status + stale detection
  wt merge [name]        Merge worktree into its base branch
                          Auto-detects from current dir if no name given
                          Includes pre-merge diff, lockfile for parallel safety
  wt rebase [name]       Rebase worktree branch onto its base branch
                          Auto-detects from current dir if no name given
                          Fetches origin first, shows commits being rebased
  wt cleanup <name>      Remove a worktree (prompts for confirmation)
                          Auto-detects from current dir if no name given
  wt done [name]         Post-merge cleanup: remove worktree, delete branch,
                          checkout base, pull. Auto-detects from current dir.
  wt prune [--stale|--all]  Batch-remove worktrees
                          (default) interactive: prompt for each worktree
                          --stale: only stale (>7d) and broken worktrees
                          --all: all worktrees (no per-item prompt)
  wt cd <name>           cd into an existing worktree
  wt help                Show this help message

Aliases: wt list = wt ls, wt cleanup = wt rm

What wt creates:
  .worktrees/<name>/              The worktree directory
  .worktrees/<name>/.worktree.json   Metadata (branch, base, timestamps)
  .worktrees/<name>/CLAUDE.md        Appends isolation context for Claude
  .worktrees/<name>/.claude/         Symlinked hooks/skills, copied settings
  .worktrees/<name>/.claude/hookify.worktree-boundary.local.md
                                     Boundary guard (warns on cross-worktree edits)

Main repo integration:
  .gitignore             Auto-adds .worktrees/ if missing
  CLAUDE.md              Auto-updates worktree map between
                         <!-- WORKTREE-MAP-START --> and <!-- WORKTREE-MAP-END -->
                         (if markers exist, otherwise skipped)

Optional main repo guard:
  Install wt-guard.sh as a PreToolUse hook to prompt when editing
  source files in the main repo while worktrees exist.
  See: ~/.claude/scripts/wt-guard.sh for installation instructions.

Requirements: git, jq

Reload after changes:
  source ~/.zshrc
HELP
}

_wt_prune() {
  local mode="interactive"  # interactive, stale, all
  case "$1" in
    --stale) mode="stale" ;;
    --all)   mode="all" ;;
  esac

  local repo_root
  repo_root="$(_wt_ensure_git_root)" || return 1

  local worktrees_dir="$repo_root/.worktrees"

  if [ ! -d "$worktrees_dir" ]; then
    echo "No .worktrees/ directory found. Nothing to prune."
    return 0
  fi

  # Collect candidates (use 1-based indexing for zsh compat)
  local candidates names branches statuses ages
  candidates=() names=() branches=() statuses=() ages=()
  local count=0
  local name meta branch base wt_status last_commit commit_epoch now_epoch age_days
  local dominated

  while IFS= read -r entry; do
    [ -z "$entry" ] && continue
    [ ! -d "$entry" ] && continue

    name="$(basename "$entry")"
    meta="$entry/.worktree.json"

    branch="-"
    wt_status="unknown"
    age_days=0

    if [ -f "$meta" ] && command -v jq &>/dev/null; then
      branch="$(jq -r '.branch // "-"' "$meta" 2>/dev/null)"
      wt_status="$(jq -r '.status // "unknown"' "$meta" 2>/dev/null)"
    fi

    if [ -d "$entry/.git" ] || [ -f "$entry/.git" ]; then
      commit_epoch="$(git -C "$entry" log -1 --format='%ct' 2>/dev/null || echo "0")"
      now_epoch="$(date +%s)"
      age_days=$(( (now_epoch - commit_epoch) / 86400 ))
      if [ "$age_days" -gt 7 ]; then
        wt_status="stale"
      fi
    elif [ ! -f "$meta" ]; then
      wt_status="broken"
    fi

    # Filter based on mode
    dominated=false
    case "$mode" in
      stale)
        if [ "$wt_status" = "stale" ] || [ "$wt_status" = "broken" ]; then
          dominated=true
        fi
        ;;
      all)
        dominated=true
        ;;
      interactive)
        dominated=true
        ;;
    esac

    if [ "$dominated" = true ]; then
      count=$((count + 1))
      candidates[$count]="$entry"
      names[$count]="$name"
      branches[$count]="$branch"
      statuses[$count]="$wt_status"
      ages[$count]="$age_days"
    fi
  done < <(find "$worktrees_dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)

  if [ "$count" -eq 0 ]; then
    echo "No worktrees to prune."
    git -C "$repo_root" worktree prune
    return 0
  fi

  echo ""
  echo "Worktrees to prune ($mode mode):"
  echo ""
  printf "  %-25s %-20s %-10s %s\n" "NAME" "BRANCH" "STATUS" "AGE (days)"
  printf "  %-25s %-20s %-10s %s\n" "----" "------" "------" "----------"
  local i=1
  while [ "$i" -le "$count" ]; do
    printf "  %-25s %-20s %-10s %s\n" "${names[$i]}" "${branches[$i]}" "${statuses[$i]}" "${ages[$i]}"
    i=$((i + 1))
  done
  echo ""

  local approve_all=false
  [ "$mode" = "all" ] && approve_all=true
  local removed=0
  local entry wt_name wt_branch wt_stat

  i=1
  while [ "$i" -le "$count" ]; do
    entry="${candidates[$i]}"
    wt_name="${names[$i]}"
    wt_branch="${branches[$i]}"
    wt_stat="${statuses[$i]}"

    if [ "$approve_all" = true ]; then
      # Auto-approve remaining
      true
    elif [ "$mode" = "interactive" ] || [ "$mode" = "stale" ]; then
      printf "Remove '%s' (branch: %s, status: %s)? [y/N/a] " "$wt_name" "$wt_branch" "$wt_stat"
      read -r REPLY
      case "$REPLY" in
        [Yy]) ;;
        [Aa]) approve_all=true ;;
        *)    echo "  Skipped."; i=$((i + 1)); continue ;;
      esac
    fi

    # Kill any processes running inside the worktree
    if ! _wt_kill_procs "$entry" "$wt_name" "$approve_all"; then
      echo "  Skipped '$wt_name' (processes still running)."
      i=$((i + 1))
      continue
    fi

    # Remove worktree (reuse _wt_cleanup's removal logic)

    # If we're inside the worktree being removed, move out
    if [[ "$(pwd)/" == "$entry/"* ]]; then
      cd "$repo_root" || true
    fi

    git -C "$repo_root" worktree remove "$entry" --force 2>/dev/null || {
      rm -rf "$entry"
      git -C "$repo_root" worktree prune
    }
    echo "  Removed worktree '$wt_name'."

    # Optionally delete branch
    if [ -n "$wt_branch" ] && [ "$wt_branch" != "-" ]; then
      if [ "$approve_all" = true ]; then
        git -C "$repo_root" branch -d "$wt_branch" 2>/dev/null || git -C "$repo_root" branch -D "$wt_branch" 2>/dev/null
        echo "  Deleted branch '$wt_branch'."
      else
        printf "  Delete branch '%s'? [y/N] " "$wt_branch"
        read -r REPLY
        if [[ "$REPLY" =~ ^[Yy]$ ]]; then
          git -C "$repo_root" branch -d "$wt_branch" 2>/dev/null || git -C "$repo_root" branch -D "$wt_branch" 2>/dev/null
          echo "  Deleted branch '$wt_branch'."
        fi
      fi
    fi

    removed=$((removed + 1))
    i=$((i + 1))
  done

  # Clean up git's internal refs
  git -C "$repo_root" worktree prune

  # Update main CLAUDE.md map
  _wt_update_main_claude_md "$repo_root"

  echo ""
  echo "Pruned $removed worktree(s). Git worktree refs cleaned."
}

_wt_rebase() {
  _wt_check_jq || return 1

  local name="$1"
  local repo_root meta worktree_path

  repo_root="$(_wt_ensure_git_root)" || return 1

  if [ -n "$name" ]; then
    worktree_path="$repo_root/.worktrees/$name"
    if [ ! -d "$worktree_path" ]; then
      echo "Error: Worktree '$name' not found at $worktree_path" >&2
      return 1
    fi
    meta="$worktree_path/.worktree.json"
  else
    # Auto-detect from current directory
    worktree_path="$(pwd)"
    meta="$worktree_path/.worktree.json"
  fi

  if [ ! -f "$meta" ]; then
    echo "Error: Not in a managed worktree (no .worktree.json found)." >&2
    echo "Usage: wt rebase [name]  (run from worktree or pass name)" >&2
    return 1
  fi

  local branch base_branch
  branch="$(jq -r '.branch' "$meta")"
  base_branch="$(jq -r '.base_branch' "$meta")"
  name="${name:-$branch}"

  echo "Rebasing worktree '$name' (branch: $branch) onto '$base_branch'"
  echo ""

  # Check for uncommitted changes
  if ! git -C "$worktree_path" diff --quiet 2>/dev/null || ! git -C "$worktree_path" diff --cached --quiet 2>/dev/null; then
    echo "Error: Uncommitted changes in worktree '$name':" >&2
    git -C "$worktree_path" status --short
    echo ""
    echo "Commit or stash changes before rebasing." >&2
    return 1
  fi

  # Determine rebase target — prefer origin/<base> for latest remote state
  local rebase_target="$base_branch"
  if git -C "$repo_root" rev-parse --verify "origin/$base_branch" &>/dev/null; then
    echo "Fetching latest from origin..."
    if git -C "$repo_root" fetch origin "$base_branch" 2>&1; then
      rebase_target="origin/$base_branch"
    else
      echo "Warning: fetch failed, rebasing onto local '$base_branch'."
    fi
  fi

  # Show what will be rebased
  local commits
  commits="$(git -C "$worktree_path" log --oneline "${rebase_target}..HEAD" 2>/dev/null)"
  if [ -z "$commits" ]; then
    echo "Branch '$branch' is already up to date with '$rebase_target'."
    return 0
  fi

  echo "Commits to rebase onto '$rebase_target':"
  echo "$commits"
  echo ""

  _wt_prompt "Proceed with rebase? [y/N]"
  if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    return 0
  fi

  # Perform rebase
  if git -C "$worktree_path" rebase "$rebase_target"; then
    echo ""
    echo "Rebased '$branch' onto '$rebase_target' successfully."
  else
    echo ""
    echo "Rebase conflict — resolve in: $worktree_path" >&2
    echo "  git -C $worktree_path rebase --continue" >&2
    echo "  git -C $worktree_path rebase --abort" >&2
    return 1
  fi
}

_wt_done() {
  local name="$1"

  _wt_check_jq || return 1

  local repo_root
  repo_root="$(_wt_ensure_git_root)" || return 1

  # Auto-detect from current directory if no name given
  if [ -z "$name" ]; then
    if [ -f "$PWD/.worktree.json" ]; then
      name="$(jq -r '.branch' "$PWD/.worktree.json" 2>/dev/null)"
    fi
    if [ -z "$name" ]; then
      echo "Usage: wt done [name]  (run from worktree or pass name)" >&2
      return 1
    fi
  fi

  local worktree_path="$repo_root/.worktrees/$name"

  if [ ! -d "$worktree_path" ]; then
    echo "Error: Worktree '$name' not found at $worktree_path" >&2
    return 1
  fi

  # Read metadata
  local meta="$worktree_path/.worktree.json"
  local branch="$name"
  local base_branch="main"
  if [ -f "$meta" ]; then
    branch="$(jq -r '.branch // "'"$name"'"' "$meta" 2>/dev/null)"
    base_branch="$(jq -r '.base_branch // "main"' "$meta" 2>/dev/null)"
  fi

  # Warn about uncommitted changes
  if ! git -C "$worktree_path" diff --quiet 2>/dev/null || ! git -C "$worktree_path" diff --cached --quiet 2>/dev/null; then
    echo "Warning: Worktree '$name' has uncommitted changes:"
    git -C "$worktree_path" status --short
    echo ""
    _wt_prompt "Continue? Uncommitted changes will be lost. [y/N]"
    if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
      echo "Aborted."
      return 1
    fi
  fi

  echo "Finishing worktree '$name' (branch: $branch, base: $base_branch)"
  echo ""

  # Kill processes in the worktree
  _wt_kill_procs "$worktree_path" "$name" "true" || return 1

  # Move out if inside the worktree
  if [[ "$(pwd)/" == "$worktree_path/"* ]]; then
    cd "$repo_root" || return 1
  fi

  # Remove worktree
  git -C "$repo_root" worktree remove "$worktree_path" --force 2>/dev/null || {
    rm -rf "$worktree_path"
    git -C "$repo_root" worktree prune
  }
  echo "Removed worktree '$name'."

  # Delete local branch
  git -C "$repo_root" branch -d "$branch" 2>/dev/null || git -C "$repo_root" branch -D "$branch" 2>/dev/null
  echo "Deleted local branch '$branch'."

  # Delete remote branch
  if git -C "$repo_root" ls-remote --exit-code --heads origin "$branch" &>/dev/null; then
    _wt_prompt "Delete remote branch 'origin/$branch'? [Y/n]"
    if [[ ! "$REPLY" =~ ^[Nn]$ ]]; then
      git -C "$repo_root" push origin --delete "$branch" 2>/dev/null && echo "Deleted remote branch '$branch'." || echo "Warning: Could not delete remote branch."
    fi
  fi

  # Checkout base branch and pull
  echo ""
  git -C "$repo_root" checkout "$base_branch" && git -C "$repo_root" pull
  echo ""

  # Update main CLAUDE.md map
  _wt_update_main_claude_md "$repo_root"

  echo "Done. You're on '$base_branch' at $repo_root"
}

# ─── Dispatcher ──────────────────────────────────────────────────────────────

wt() {
  if [ "$1" = "--" ]; then shift; _wt_create "$@"; return $?; fi
  case "$1" in
    list|ls)        shift; _wt_list "$@" ;;
    merge)          shift; _wt_merge "$@" ;;
    rebase)         shift; _wt_rebase "$@" ;;
    cleanup|rm)     shift; _wt_cleanup "$@" ;;
    done)           shift; _wt_done "$@" ;;
    prune)          shift; _wt_prune "$@" ;;
    cd)             shift; _wtc "$@" ;;
    help|-h|--help) _wt_help ;;
    *)              _wt_create "$@" ;;
  esac
}

# ─── Backward-Compat Wrappers ───────────────────────────────────────────────

wt-list()    { wt list "$@"; }
wt-merge()   { wt merge "$@"; }
wt-rebase()  { wt rebase "$@"; }
wt-done()    { wt done "$@"; }
wt-cleanup() { wt cleanup "$@"; }
wt-prune()   { wt prune "$@"; }
wtc()        { wt cd "$@"; }
wt-help()    { wt help; }
