#!/usr/bin/env bats
# Tests for _wt_check_merged in wt.sh
#
# Scenarios:
#   1. Regular merge: merge-base sees branch as ancestor → merged (0)
#   2. Squash/rebase merge: merge-base fails but gh finds merged PR → merged (0)
#   3. Unmerged branch: merge-base fails and gh finds no merged PR → not merged (1)
#   4. gh not installed: merge-base fails, no gh → not merged (1), no crash
#   5. gh auth failure: merge-base fails, gh exits non-zero → not merged (1), no crash
#   6. Fetch is targeted to base_branch only, not all refs

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"

setup() {
  MOCK_DIR="$(mktemp -d)"
  MOCK_FETCH_ARGS_FILE="$BATS_TEST_TMPDIR/git_fetch_args"
  ORIG_PATH="$PATH"

  # Mock git: fetch always succeeds; merge-base exit controlled by MOCK_MERGE_BASE_EXIT
  cat > "$MOCK_DIR/git" << 'EOF'
#!/bin/bash
while [[ "$1" == "-C" ]]; do shift 2; done
case "$1" in
  fetch)
    shift  # skip "fetch"
    echo "$@" > "$MOCK_FETCH_ARGS_FILE"
    exit 0
    ;;
  merge-base)
    exit "${MOCK_MERGE_BASE_EXIT:-1}"
    ;;
  *)
    /usr/bin/git "$@"
    ;;
esac
EOF
  chmod +x "$MOCK_DIR/git"

  # Mock gh: output controlled by MOCK_GH_PR_COUNT; exit by MOCK_GH_EXIT
  cat > "$MOCK_DIR/gh" << 'EOF'
#!/bin/bash
if [ "${MOCK_GH_EXIT:-0}" -ne 0 ]; then
  echo "error: authentication required" >&2
  exit "${MOCK_GH_EXIT}"
fi
echo "${MOCK_GH_PR_COUNT:-0}"
EOF
  chmod +x "$MOCK_DIR/gh"

  export MOCK_DIR MOCK_FETCH_ARGS_FILE ORIG_PATH
  export PATH="$MOCK_DIR:$PATH"

  # Load wt.sh functions (jq warning to /dev/null)
  source "$SCRIPT_DIR/wt.sh" 2>/dev/null
}

teardown() {
  rm -rf "$MOCK_DIR"
  PATH="$ORIG_PATH"
}

# ── Regular merge ───────────────────────────────────────────────────────────

@test "regular merge: branch is ancestor of origin/base → returns merged" {
  export MOCK_MERGE_BASE_EXIT=0
  run _wt_check_merged "/fake/repo" "feature-branch" "main"
  [ "$status" -eq 0 ]
}

# ── Squash / rebase merge ───────────────────────────────────────────────────

@test "squash merge: merge-base fails but gh finds merged PR → returns merged" {
  export MOCK_MERGE_BASE_EXIT=1
  export MOCK_GH_PR_COUNT=1
  run _wt_check_merged "/fake/repo" "feature-branch" "main"
  [ "$status" -eq 0 ]
}

@test "squash merge: gh finds 2 merged PRs (multiple branches) → returns merged" {
  export MOCK_MERGE_BASE_EXIT=1
  export MOCK_GH_PR_COUNT=2
  run _wt_check_merged "/fake/repo" "feature-branch" "main"
  [ "$status" -eq 0 ]
}

# ── Unmerged branch ─────────────────────────────────────────────────────────

@test "unmerged branch: merge-base fails and gh finds no merged PR → returns not merged" {
  export MOCK_MERGE_BASE_EXIT=1
  export MOCK_GH_PR_COUNT=0
  run _wt_check_merged "/fake/repo" "feature-branch" "main"
  [ "$status" -eq 1 ]
}

# ── gh unavailable ──────────────────────────────────────────────────────────

@test "gh not installed: merge-base fails, no gh on PATH → returns not merged without crash" {
  rm -f "$MOCK_DIR/gh"
  export MOCK_MERGE_BASE_EXIT=1
  # Strip homebrew bin so system gh is also absent
  export PATH="$MOCK_DIR:/bin:/usr/bin:/usr/local/bin:/usr/sbin:/sbin"
  run _wt_check_merged "/fake/repo" "feature-branch" "main"
  [ "$status" -eq 1 ]
}

@test "gh auth failure: merge-base fails, gh exits non-zero → returns not merged without crash" {
  export MOCK_MERGE_BASE_EXIT=1
  export MOCK_GH_EXIT=1
  run _wt_check_merged "/fake/repo" "feature-branch" "main"
  [ "$status" -eq 1 ]
}

@test "gh returns empty output: treated as zero count → returns not merged" {
  export MOCK_MERGE_BASE_EXIT=1
  export MOCK_GH_PR_COUNT=""
  run _wt_check_merged "/fake/repo" "feature-branch" "main"
  [ "$status" -eq 1 ]
}

# ── Targeted fetch ──────────────────────────────────────────────────────────

@test "fetch uses base_branch argument, not bare 'fetch origin'" {
  export MOCK_MERGE_BASE_EXIT=0
  _wt_check_merged "/fake/repo" "feature-branch" "main"
  [ -f "$MOCK_FETCH_ARGS_FILE" ]
  fetch_args="$(cat "$MOCK_FETCH_ARGS_FILE")"
  [ "$fetch_args" = "origin main --quiet" ]
}
