#!/usr/bin/env bash
# br.sh — Lightweight Branch Management for Claude Code
# Source from ~/.zshrc. Provides: br (done, list, cleanup, pr, pr-done, help)
# Legacy aliases: br-done, br-pr, br-pr-done, br-list, br-cleanup, br-help
#
# Tracks "what branch did I branch from?" so you don't have to remember.
# Metadata stored in .git/branch-meta/<name>.json (local, not tracked).
#
# Requires: jq, git, gh (for br-pr/br-pr-done)

# ─── Dependency Check ────────────────────────────────────────────────────────

if ! command -v jq &>/dev/null; then
  echo "br.sh: Warning — jq is required but not installed. Install with: brew install jq" >&2
fi

# ─── Helpers ─────────────────────────────────────────────────────────────────

_br_check_jq() {
  if ! command -v jq &>/dev/null; then
    echo "Error: jq is required. Install with: brew install jq" >&2
    return 1
  fi
}

_br_check_gh() {
  if ! command -v gh &>/dev/null; then
    echo "Error: gh (GitHub CLI) is required. Install with: brew install gh" >&2
    return 1
  fi
}

_br_ensure_git() {
  if ! git rev-parse --is-inside-work-tree &>/dev/null; then
    echo "Error: Not inside a git repository." >&2
    return 1
  fi
}

_br_git_dir() {
  git rev-parse --git-dir
}

_br_meta_dir() {
  echo "$(_br_git_dir)/branch-meta"
}

_br_meta_file() {
  local name="$1"
  echo "$(_br_meta_dir)/${name}.json"
}

_br_prompt() {
  local prompt_text="$1"
  printf "%s " "$prompt_text"
  read -r REPLY
}

_br_current_branch() {
  git branch --show-current
}

_br_time_ago() {
  local created="$1"
  local now created_epoch age_seconds

  # Parse ISO date to epoch
  if date -j -f "%Y-%m-%dT%H:%M:%SZ" "2000-01-01T00:00:00Z" "+%s" &>/dev/null; then
    # macOS
    created_epoch="$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$created" "+%s" 2>/dev/null || echo "0")"
  else
    # Linux
    created_epoch="$(date -d "$created" "+%s" 2>/dev/null || echo "0")"
  fi

  now="$(date +%s)"
  age_seconds=$((now - created_epoch))

  if [ "$age_seconds" -lt 60 ]; then
    echo "just now"
  elif [ "$age_seconds" -lt 3600 ]; then
    echo "$((age_seconds / 60)) minutes ago"
  elif [ "$age_seconds" -lt 86400 ]; then
    echo "$((age_seconds / 3600)) hours ago"
  else
    echo "$((age_seconds / 86400)) days ago"
  fi
}

# ─── Main Functions ──────────────────────────────────────────────────────────

_br_create() {
  local name="$1"
  local base="$2"

  if [ -z "$name" ]; then
    echo "Usage: br <name> [base-branch]"
    echo "  Creates a branch and tracks its base for easy merge-back"
    echo ""
    echo "Subcommands:"
    echo "  br done [name]       Merge branch back into its base (local)"
    echo "  br pr [name]         Push and create PR targeting base"
    echo "  br pr-done [name]    Clean up after PR is merged"
    echo "  br list              List tracked branches"
    echo "  br cleanup <name>    Delete branch without merging"
    echo "  br help              Show full help"
    return 1
  fi

  _br_ensure_git || return 1
  _br_check_jq || return 1

  # Validate branch name
  if ! git check-ref-format --branch "$name" &>/dev/null; then
    echo "Error: '$name' is not a valid branch name." >&2
    return 1
  fi

  # Check branch doesn't already exist
  if git show-ref --verify --quiet "refs/heads/$name" 2>/dev/null; then
    echo "Error: Branch '$name' already exists." >&2
    return 1
  fi

  # Resolve base branch
  local base_branch
  if [ -n "$base" ]; then
    # Verify base exists
    if ! git show-ref --verify --quiet "refs/heads/$base" 2>/dev/null; then
      echo "Error: Base branch '$base' does not exist." >&2
      return 1
    fi
    base_branch="$base"
  else
    base_branch="$(_br_current_branch)"
    if [ -z "$base_branch" ]; then
      echo "Error: Detached HEAD — specify a base branch explicitly." >&2
      return 1
    fi
  fi

  # Create metadata directory
  local meta_dir
  meta_dir="$(_br_meta_dir)"
  mkdir -p "$meta_dir"

  # Create branch
  git checkout -b "$name" "$base_branch" || return 1

  # Write metadata
  local now meta_file tmp_meta
  now="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  meta_file="$(_br_meta_file "$name")"
  tmp_meta="$(mktemp)"
  jq -n \
    --arg branch "$name" \
    --arg base_branch "$base_branch" \
    --arg created "$now" \
    '{branch: $branch, base_branch: $base_branch, created: $created}' \
    > "$tmp_meta"
  mv "$tmp_meta" "$meta_file"

  echo ""
  echo "Branch '$name' created from '$base_branch'"
  echo "  Metadata: $meta_file"
  echo "  Run 'br done' when ready to merge back"
}

_br_done() {
  _br_ensure_git || return 1
  _br_check_jq || return 1

  local name="$1"

  # Auto-detect current branch if no name given
  if [ -z "$name" ]; then
    name="$(_br_current_branch)"
    if [ -z "$name" ]; then
      echo "Error: Detached HEAD — specify branch name explicitly." >&2
      return 1
    fi
  fi

  # Read metadata
  local meta_file
  meta_file="$(_br_meta_file "$name")"

  if [ ! -f "$meta_file" ]; then
    echo "Error: No metadata for branch '$name'." >&2
    echo "  (Only branches created with 'br' are tracked)" >&2
    return 1
  fi

  local base_branch
  base_branch="$(jq -r '.base_branch' "$meta_file")"

  if [ -z "$base_branch" ] || [ "$base_branch" = "null" ]; then
    echo "Error: Could not read base branch from metadata." >&2
    return 1
  fi

  # Verify base branch still exists
  if ! git show-ref --verify --quiet "refs/heads/$base_branch" 2>/dev/null; then
    echo "Error: Base branch '$base_branch' no longer exists." >&2
    return 1
  fi

  # Check for uncommitted changes
  if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
    echo "Warning: Uncommitted changes:"
    git status --short
    echo ""
    _br_prompt "Continue? Uncommitted changes will NOT be merged. [y/N]"
    if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
      echo "Aborted."
      return 1
    fi
  fi

  # Show diff summary
  echo ""
  echo "Branch:  $name"
  echo "Base:    $base_branch"
  echo ""

  local commits
  commits="$(git log "${base_branch}..${name}" --oneline 2>/dev/null)"
  if [ -z "$commits" ]; then
    echo "No new commits to merge."
    _br_prompt "Clean up branch anyway? [y/N]"
    if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
      echo "Aborted."
      return 0
    fi
  else
    local commit_count
    commit_count="$(echo "$commits" | wc -l | tr -d ' ')"
    echo "Commits ($commit_count):"
    echo "$commits"
    echo ""
    git diff --stat "${base_branch}..${name}" 2>/dev/null
    echo ""
    _br_prompt "Merge into '$base_branch'? [y/N]"
    if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
      echo "Aborted."
      return 0
    fi
  fi

  # Switch to base and merge
  git checkout "$base_branch" || {
    echo "Error: Could not checkout '$base_branch'." >&2
    return 1
  }

  if git merge "$name"; then
    echo ""
    echo "Merged '$name' into '$base_branch'."
  else
    echo ""
    echo "Error: Merge failed. Resolve conflicts, then clean up with:" >&2
    echo "  git branch -d $name" >&2
    echo "  rm $meta_file" >&2
    return 1
  fi

  # Delete feature branch
  git branch -d "$name" 2>/dev/null || git branch -D "$name"
  echo "Deleted branch '$name'."

  # Clean up metadata
  rm -f "$meta_file"
  echo "Cleaned up metadata."

  echo ""
  echo "Done. Now on '$base_branch'."
}

_br_list() {
  _br_ensure_git || return 1

  local meta_dir
  meta_dir="$(_br_meta_dir)"

  if [ ! -d "$meta_dir" ]; then
    echo "No tracked branches. Use 'br <name>' to create one."
    return 0
  fi

  local has_entries=false

  echo ""
  printf "%-25s %-20s %-20s %s\n" "BRANCH" "BASE" "CREATED" "STATUS"
  printf "%-25s %-20s %-20s %s\n" "------" "----" "-------" "------"

  for meta_file in "$meta_dir"/*.json; do
    [ ! -f "$meta_file" ] && continue
    has_entries=true

    local branch base_branch created br_status age

    branch="$(jq -r '.branch // "-"' "$meta_file")"
    base_branch="$(jq -r '.base_branch // "-"' "$meta_file")"
    created="$(jq -r '.created // "-"' "$meta_file")"

    # Check if branch still exists
    if ! git show-ref --verify --quiet "refs/heads/$branch" 2>/dev/null; then
      br_status="deleted"
    elif git merge-base --is-ancestor "$branch" "$base_branch" 2>/dev/null; then
      br_status="merged"
    else
      br_status="active"
    fi

    # Format age
    if [ "$created" != "-" ]; then
      age="$(_br_time_ago "$created")"
    else
      age="-"
    fi

    printf "%-25s %-20s %-20s %s\n" "$branch" "$base_branch" "$age" "$br_status"
  done

  if [ "$has_entries" = false ]; then
    echo "(no tracked branches)"
  fi

  echo ""
}

_br_cleanup() {
  _br_ensure_git || return 1

  local name="$1"

  if [ -z "$name" ]; then
    # Auto-detect current branch
    name="$(_br_current_branch)"
    if [ -z "$name" ]; then
      echo "Usage: br cleanup <name>" >&2
      return 1
    fi
  fi

  local meta_file
  meta_file="$(_br_meta_file "$name")"

  # Check if branch exists
  local branch_exists=false
  if git show-ref --verify --quiet "refs/heads/$name" 2>/dev/null; then
    branch_exists=true
  fi

  if [ "$branch_exists" = false ] && [ ! -f "$meta_file" ]; then
    echo "Error: Branch '$name' not found and no metadata exists." >&2
    return 1
  fi

  if [ "$branch_exists" = true ]; then
    # Check if unmerged
    local base_branch=""
    if [ -f "$meta_file" ]; then
      base_branch="$(jq -r '.base_branch // ""' "$meta_file")"
    fi

    local is_merged=false
    if [ -n "$base_branch" ] && git merge-base --is-ancestor "$name" "$base_branch" 2>/dev/null; then
      is_merged=true
    fi

    if [ "$is_merged" = true ]; then
      _br_prompt "Delete branch '$name' (already merged into '$base_branch')? [y/N]"
    else
      echo "Warning: Branch '$name' has unmerged changes."
      if [ -n "$base_branch" ]; then
        local commit_count
        commit_count="$(git log "${base_branch}..${name}" --oneline 2>/dev/null | wc -l | tr -d ' ')"
        echo "  $commit_count commit(s) not in '$base_branch'"
      fi
      _br_prompt "Delete anyway? This is irreversible. [y/N]"
    fi

    if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
      echo "Aborted."
      return 0
    fi

    # If we're on the branch being deleted, switch away
    if [ "$(_br_current_branch)" = "$name" ]; then
      local switch_to="${base_branch:-main}"
      if ! git show-ref --verify --quiet "refs/heads/$switch_to" 2>/dev/null; then
        switch_to="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
        if [ "$switch_to" = "$name" ]; then
          switch_to="main"
        fi
      fi
      git checkout "$switch_to" || {
        echo "Error: Could not switch away from '$name'." >&2
        return 1
      }
    fi

    git branch -D "$name"
    echo "Deleted branch '$name'."
  fi

  # Clean up metadata
  if [ -f "$meta_file" ]; then
    rm -f "$meta_file"
    echo "Cleaned up metadata."
  fi

  echo "Done."
}

_br_pr() {
  _br_ensure_git || return 1
  _br_check_jq || return 1
  _br_check_gh || return 1

  local name="$1"
  local explicit_name=false

  # Auto-detect current branch
  if [ -n "$name" ]; then
    explicit_name=true
  else
    name="$(_br_current_branch)"
    if [ -z "$name" ]; then
      echo "Error: Detached HEAD — specify branch name explicitly." >&2
      return 1
    fi
  fi

  # Read metadata
  local meta_file
  meta_file="$(_br_meta_file "$name")"

  if [ ! -f "$meta_file" ]; then
    echo "Error: No metadata for branch '$name'." >&2
    echo "  (Only branches created with 'br' are tracked)" >&2
    return 1
  fi

  local base_branch
  base_branch="$(jq -r '.base_branch' "$meta_file")"

  if [ -z "$base_branch" ] || [ "$base_branch" = "null" ]; then
    echo "Error: Could not read base branch from metadata." >&2
    return 1
  fi

  # Check for uncommitted changes
  if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
    echo "Warning: Uncommitted changes:"
    git status --short
    echo ""
    _br_prompt "Continue? Uncommitted changes will NOT be included. [y/N]"
    if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
      echo "Aborted."
      return 1
    fi
  fi

  # Show what will be in the PR
  echo ""
  echo "Branch:  $name"
  echo "Base:    $base_branch"
  echo ""

  local commits
  commits="$(git log "${base_branch}..${name}" --oneline 2>/dev/null)"
  if [ -z "$commits" ]; then
    echo "No commits ahead of '$base_branch'. Nothing to PR."
    return 1
  fi

  local commit_count
  commit_count="$(echo "$commits" | wc -l | tr -d ' ')"
  echo "Commits ($commit_count):"
  echo "$commits"
  echo ""
  git diff --stat "${base_branch}..${name}" 2>/dev/null
  echo ""

  # Push branch
  echo "Pushing '$name' to remote..."
  git push -u origin "$name" || {
    echo "Error: Push failed." >&2
    return 1
  }

  echo ""

  # Create PR — pass through to gh, let user fill in title/body interactively
  # Pass any extra args after name to gh
  [ "$explicit_name" = true ] && shift
  gh pr create --base "$base_branch" "$@"
}

_br_pr_done() {
  _br_ensure_git || return 1
  _br_check_jq || return 1

  local name="$1"

  # Auto-detect current branch
  if [ -z "$name" ]; then
    name="$(_br_current_branch)"
    if [ -z "$name" ]; then
      echo "Error: Detached HEAD — specify branch name explicitly." >&2
      return 1
    fi
  fi

  # Read metadata
  local meta_file
  meta_file="$(_br_meta_file "$name")"

  if [ ! -f "$meta_file" ]; then
    echo "Error: No metadata for branch '$name'." >&2
    echo "  (Only branches created with 'br' are tracked)" >&2
    return 1
  fi

  local base_branch
  base_branch="$(jq -r '.base_branch' "$meta_file")"

  if [ -z "$base_branch" ] || [ "$base_branch" = "null" ]; then
    echo "Error: Could not read base branch from metadata." >&2
    return 1
  fi

  # Verify the PR is actually merged (if gh is available)
  if command -v gh &>/dev/null; then
    local pr_state
    pr_state="$(gh pr view "$name" --json state --jq '.state' 2>/dev/null)"
    if [ "$pr_state" = "OPEN" ]; then
      echo "Warning: PR for '$name' is still open."
      _br_prompt "Continue cleanup anyway? [y/N]"
      if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
        echo "Aborted."
        return 0
      fi
    elif [ "$pr_state" = "MERGED" ]; then
      echo "PR for '$name' is merged."
    fi
  fi

  # Check for uncommitted changes on current branch
  if [ "$(_br_current_branch)" = "$name" ]; then
    if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
      echo "Warning: Uncommitted changes on '$name':"
      git status --short
      echo ""
      _br_prompt "Continue? Uncommitted changes will be lost. [y/N]"
      if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
        echo "Aborted."
        return 1
      fi
    fi
  fi

  # Switch to base branch and pull
  echo "Switching to '$base_branch'..."
  git checkout "$base_branch" || {
    echo "Error: Could not checkout '$base_branch'." >&2
    return 1
  }

  echo "Pulling latest '$base_branch'..."
  git pull || {
    echo "Warning: Pull failed. Continuing with cleanup." >&2
  }

  # Delete local branch
  git branch -d "$name" 2>/dev/null || git branch -D "$name"
  echo "Deleted local branch '$name'."

  # Delete remote branch
  if git ls-remote --exit-code --heads origin "$name" &>/dev/null; then
    _br_prompt "Delete remote branch 'origin/$name'? [Y/n]"
    if [[ ! "$REPLY" =~ ^[Nn]$ ]]; then
      git push origin --delete "$name" 2>/dev/null && echo "Deleted remote branch 'origin/$name'."
    fi
  fi

  # Clean up metadata
  rm -f "$meta_file"
  echo "Cleaned up metadata."

  echo ""
  echo "Done. Now on '$base_branch'."
}

_br_help() {
  cat <<'HELP'
Lightweight Branch Management for Claude Code
==============================================

Usage:
  br <name> [base]       Create branch and track its base
                          base defaults to current branch
  br -- <name>            Force create (bypass subcommand matching)

Subcommands:
  br done [name]         Merge branch back into its base (local)
                          Auto-detects current branch if no name given
                          Shows diff summary, prompts before merge

  br pr [name]           Push branch and create PR targeting base
                          Auto-detects current branch if no name given
                          Extra args passed to gh pr create

  br pr-done [name]      Clean up after PR is merged
                          Switches to base, pulls, deletes local + remote branch
                          Checks PR merge status via gh

  br list                List tracked branches with status
                          Shows: name, base, age, merged/active/deleted

  br cleanup [name]      Delete branch and metadata without merging
                          Auto-detects current branch if no name given
                          Warns if branch has unmerged changes

  br help                Show this help message

Aliases: br list = br ls, br cleanup = br rm

Metadata:
  Stored in .git/branch-meta/<name>.json (local, not tracked by git)
  Contains: branch name, base branch, creation timestamp

Requirements: git, jq, gh (for br pr/br pr-done)
HELP
}

# ─── Dispatcher ──────────────────────────────────────────────────────────────

br() {
  if [ "$1" = "--" ]; then shift; _br_create "$@"; return $?; fi
  case "$1" in
    done)           shift; _br_done "$@" ;;
    list|ls)        shift; _br_list "$@" ;;
    cleanup|rm)     shift; _br_cleanup "$@" ;;
    pr-done)        shift; _br_pr_done "$@" ;;
    pr)             shift; _br_pr "$@" ;;
    help|-h|--help) _br_help ;;
    *)              _br_create "$@" ;;
  esac
}

# ─── Backward-Compat Wrappers ───────────────────────────────────────────────

br-done()    { br done "$@"; }
br-list()    { br list "$@"; }
br-cleanup() { br cleanup "$@"; }
br-pr()      { br pr "$@"; }
br-pr-done() { br pr-done "$@"; }
br-help()    { br help; }
