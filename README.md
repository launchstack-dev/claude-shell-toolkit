# Claude Code Shell Toolkit

Shell scripts for running parallel [Claude Code](https://docs.anthropic.com/en/docs/claude-code) sessions with isolated workspaces, dev server management, branch tracking, and ergonomic shortcuts. Designed for Ghostty on macOS — no tmux required.

## Scripts

| Script | Purpose |
|--------|---------|
| [`wt.sh`](#wtsh--git-worktrees) | Git worktree management with Claude isolation boundaries |
| [`dev.sh`](#devsh--dev-workspace-launcher) | Dev server port allocation per worktree (Vite, Convex, Next.js) |
| [`br.sh`](#brsh--branch-management) | Lightweight branch management with base tracking |
| [`cc.sh`](#ccsh--claude-code-shortcuts) | 30+ shell shortcuts for Claude Code sessions |
| [`claude-sandbox.sb`](#kernel-sandbox) | macOS Seatbelt profile for kernel-enforced filesystem sandbox |
| [`wt-guard.sh`](#wt-guardsh--main-repo-guard) | PreToolUse hook — prompts when Claude edits source files in main repo |

## Install

```bash
# Clone into ~/.claude/scripts/ (this becomes the repo)
git clone https://github.com/launchstack-dev/git-worktree-claude.git ~/.claude/scripts

# Source in your shell (order matters: wt.sh first, dev.sh after)
cat >> ~/.zshrc << 'EOF'
source "$HOME/.claude/scripts/wt.sh"
source "$HOME/.claude/scripts/dev.sh"
source "$HOME/.claude/scripts/br.sh"
source "$HOME/.claude/scripts/cc.sh"
EOF

source ~/.zshrc

# Verify
wt help && dev help && br help && cc-help
```

**Requires:** `git`, `jq` (`brew install jq`), `gh` (for `br pr` commands)

---

## `wt.sh` — Git Worktrees

Creates isolated git worktrees with Claude-aware boundaries so parallel Claude instances don't step on each other.

### Commands

| Command | Purpose |
|---------|---------|
| `wt <name> [base]` | Create worktree, inject Claude context, cd into it |
| `wt list` | List worktrees with status + stale detection |
| `wt merge [name]` | Merge into base branch with pre-merge diff + lockfile |
| `wt cleanup <name>` | Remove worktree, update CLAUDE.md map |
| `wt cd <name>` | Quick cd into existing worktree |
| `wt help` | Show all commands |
| `wt -- <name>` | Force create (bypass subcommand matching) |

### What `wt` Creates

When you run `wt my-feature`:

1. Creates `.worktrees/my-feature/` via `git worktree add`
2. Writes `.worktree.json` metadata (branch, base branch, timestamps)
3. Symlinks shared Claude config (hooks, skills, agents) from main repo
4. Copies local Claude config (settings.json) so worktrees can diverge
5. Appends isolation rules to the worktree's `CLAUDE.md`
6. Generates a [hookify](https://github.com/anthropics/claude-code-plugins) boundary guard
7. Updates the main repo's `CLAUDE.md` worktree map (if markers exist)
8. Runs project setup (npm/bun/pip/cargo install)
9. `cd`s you into the worktree, ready to run `claude`

### Isolation Layers

| Layer | Mechanism |
|-------|-----------|
| CLAUDE.md context | Hard rules injected into each worktree's CLAUDE.md |
| Hookify boundary guard | Warns when Claude edits files outside the worktree |
| Main repo guard (optional) | `wt-guard.sh` hook prompts for main repo edits |
| Merge lockfile | PID-based lock prevents concurrent merge conflicts |

---

## `dev.sh` — Dev Workspace Launcher

Layers dev server management on top of `wt.sh`. Allocates deterministic ports per worktree so Vite, Convex, etc. don't collide across parallel sessions. Prints Ghostty split instructions with exact commands.

### Commands

| Command | Purpose |
|---------|---------|
| `dev [name] [base]` | Create/enter worktree + show workspace setup with ports |
| `dev init` | Scaffold `.devrc.json` (auto-detects vite, convex, next.js) |
| `dev ps` | Show running dev servers, flag orphans, prompt to kill |
| `dev stop [name]` | Kill dev servers for a worktree |
| `dev help` | Show all commands |
| `dev -- <name>` | Force enter (bypass subcommand matching) |

### `.devrc.json`

Lives in the project root. Defines what dev servers the project uses:

```json
{
  "services": [
    {
      "name": "vite",
      "cmd": "npx vite --port {port}",
      "port": 5173
    },
    {
      "name": "convex",
      "cmd": "npx convex dev --admin-port {port}",
      "port": 3210,
      "main_only": true
    }
  ]
}
```

- `name` — display name + used for process detection
- `cmd` — command template, `{port}` is replaced with the allocated port
- `port` — default/base port (main repo gets this exact port, worktrees get base + offset)
- `main_only` — service only runs in main repo, skipped in worktrees (e.g., Convex which shares a single cloud backend)

Run `dev init` in a project to auto-detect and generate this file.

### Port Allocation

- **Main repo** always gets default ports from `.devrc.json`
- **Worktrees** get a deterministic offset (1-99) based on a hash of the worktree name
- Collisions with other worktrees or bound ports are automatically resolved
- Ports are cached in `.ports.json` per worktree (stable across sessions, separate from `.worktree.json`)

### Workspace Output

Running `dev feature-auth` prints:

```
Worktree 'feature-auth' ready at: /path/.worktrees/feature-auth

── Workspace Setup ─────────────────────────────────────────────────
  Cmd+D (split right), then run:
    npx vite --port 5201

  Cmd+[ to return here, then run:
    claude

  Ports: vite :5201
  (first command copied to clipboard)
─────────────────────────────────────────────────────────────────────
```

The Ghostty tab title is automatically set to `wt: <name>`.

---

## `br.sh` — Branch Management

Lightweight branch management that tracks "what branch did I branch from?" so you never have to remember. Metadata is stored locally in `.git/branch-meta/` (not tracked by git).

### Commands

| Command | Purpose |
|---------|---------|
| `br <name> [base]` | Create branch and track its base |
| `br done [name]` | Merge branch back into its base (local) |
| `br pr [name]` | Push and create PR targeting base via `gh` |
| `br pr-done [name]` | Clean up after PR is merged (local + remote branch, metadata) |
| `br list` | List tracked branches with status (active/merged/deleted) |
| `br cleanup [name]` | Delete branch and metadata without merging |
| `br help` | Show all commands |
| `br -- <name>` | Force create (bypass subcommand matching) |

### Usage

```bash
br auth-feature           # branch from current, track base
# ... do work ...
br pr                     # push + gh pr create targeting base
# ... PR merged on GitHub ...
br pr-done                # checkout base, pull, delete local+remote branch
```

All commands auto-detect the current branch when no name is given.

---

## `cc.sh` — Claude Code Shortcuts

30+ shell shortcuts that wrap `claude` with common flag combinations. Shadows the system `cc` compiler — use `clang` or `gcc` directly if needed.

### Commands

**Core Session:**

| Command | Purpose |
|---------|---------|
| `cc [args]` | `claude --chrome` (passthrough) |
| `ccc [args]` | Continue last conversation |
| `ccr [search]` | Resume a conversation |
| `ccf [args]` | Fork from last conversation |

**Permission Modes:**

| Command | Purpose |
|---------|---------|
| `cc-yolo` | Skip all permission checks |
| `cc-edit` | Auto-accept edits, prompt for bash |
| `cc-plan` | Plan mode — approve before implementation |
| `cc-read` | Read-only exploration |

**Model Selection:**

| Command | Purpose |
|---------|---------|
| `cc-opus` | Use Opus |
| `cc-sonnet` | Use Sonnet |
| `cc-haiku` | Use Haiku |

**One-Shot / Piping:**

| Command | Purpose |
|---------|---------|
| `cc-q <question>` | Quick question via Haiku, no session |
| `cc-pipe <prompt> <cmd>` | Pipe command output to Claude |
| `cc-review` | Review staged/unstaged git diff |
| `cc-review-branch [base]` | Review branch diff vs base |
| `cc-explain <file>` | Explain a file's code |
| `cc-msg` | Generate commit message from staged changes |

**Compound Modes:**

| Command | Purpose |
|---------|---------|
| `cc-deep` | Opus + yolo + continue — deep autonomous work |
| `cc-fast` | Haiku + acceptEdits — quick low-stakes tasks |
| `cc-debug` | Debug + verbose + continue |
| `cc-budget <$> <prompt>` | Budget-capped one-shot (default $2) |

**Kernel Sandbox** (macOS Seatbelt — kernel-enforced filesystem restrictions):

| Command | Purpose |
|---------|---------|
| `cc-sbox` | Yolo inside kernel sandbox — writes scoped to project dir |
| `cc-sbox-edit` | acceptEdits inside kernel sandbox |
| `cc-sbox-deep` | Opus + yolo + continue inside kernel sandbox |
| `cc-sbox-test` | Verify sandbox boundaries (writes in/out of boundary) |

**Sandbox Modes** (least → most restricted):

| Command | Purpose |
|---------|---------|
| `cc-vm` | Full autonomy, for Docker/VM (formerly `cc-sandbox`) |
| `cc-nobash` | Read + edit, no shell |
| `cc-nonet` | No web access |
| `cc-jail` | Read-only, no bash, no network |

**Multi-Repo / Integrations:**

| Command | Purpose |
|---------|---------|
| `cc-mono <dirs> [-- args]` | Claude with access to additional directories |
| `cc-wt [name]` | Claude in worktree + tmux pane |
| `cc-pr [number\|url]` | Start from a GitHub PR |

All model and permission functions pass through args, so you can combine:
```bash
cc-opus --continue
cc-yolo --model opus
cc-edit --continue --model haiku
```

---

## Kernel Sandbox

macOS `sandbox-exec` (Seatbelt) provides kernel-enforced filesystem restrictions with zero overhead — no VM, no container. Claude gets full autonomy within the project directory, with writes blocked everywhere else by the kernel.

### How It Works

The `claude-sandbox.sb` Seatbelt profile uses a deny-default policy with three parameterized write zones:

| Zone | Path | Purpose |
|------|------|---------|
| `PROJECT_DIR` | Project/worktree root | The only writable zone for code |
| `CLAUDE_HOME` | `~/.claude` | Session state, config, memory |
| `TMPDIR_REAL` | Resolved `$TMPDIR` | Node.js temp files |

All reads are allowed — the threat model is preventing writes, not reads. SSH keys are readable (git push works) but not writable.

### Commands

```bash
cc-sbox                    # Yolo inside kernel sandbox
cc-sbox-edit               # acceptEdits inside kernel sandbox
cc-sbox-deep               # Opus + yolo + continue inside kernel sandbox
cc-sbox-test               # Verify sandbox boundaries
```

Extra args pass through to `claude`:
```bash
cc-sbox --model opus       # Model override
cc-sbox --continue         # Continue session
cc-sbox -p "fix all bugs"  # One-shot
```

### Project Directory Detection

| Context | Sandbox boundary |
|---------|-----------------|
| Inside a managed worktree | Worktree path (e.g., `.worktrees/my-feature/`) |
| In a git repo (no worktree) | Repo root |
| Not in a git repo | `$PWD` |
| `CC_SANDBOX_DIR` set | That path (manual override) |

When used inside a worktree created by `wt.sh`, the sandbox auto-scopes to the worktree path — combining git isolation with OS-level isolation.

### Limitations

- **macOS only** — requires `sandbox-exec` (Seatbelt)
- **npm/bun cache not writable** — install dependencies before entering sandbox mode
- **`npm install` uses local `node_modules/`** which IS in the project dir and works fine
- **Not a security boundary against a determined attacker** — Seatbelt has known bypasses. This prevents accidental writes, not adversarial escape.

### Verification

```bash
# Run boundary test in a project dir
cc-sbox-test

# Run from inside a worktree — confirms boundary is worktree, not repo root
cd .worktrees/my-feature && cc-sbox-test

# Manual escape test: from within Claude, try:
#   touch ~/test-escape    → should get EPERM
```

---

## `wt-guard.sh` — Main Repo Guard

Optional PreToolUse hook that prompts (doesn't block) when Claude edits source files in the main repo while worktrees exist.

### Install per project

Add to `.claude/settings.json`:

```json
{
  "hooks": {
    "PreToolUse": [{
      "matcher": "Write|Edit",
      "hooks": [{
        "type": "command",
        "command": "bash ~/.claude/scripts/wt-guard.sh",
        "timeout": 5000
      }]
    }]
  }
}
```

The guard:
- Exits immediately (zero overhead) if no `.worktrees/` directory exists
- Allows edits inside worktrees
- Allows config files (`.gitignore`, `CLAUDE.md`, `*.json`, `*.lock`, etc.)
- Prompts for source files in the main repo

---

## Per-Project Setup

### CLAUDE.md Template (Recommended)

Add to your project's `CLAUDE.md` to enable the auto-updating worktree map:

```markdown
## Git Worktree Discipline -- READ FIRST

**At session start**, verify your location:

\`\`\`bash
pwd && git branch --show-current && git worktree list
\`\`\`

### Active Worktrees

<!-- WORKTREE-MAP-START -->
| Branch | Base | Path | Status |
|--------|------|------|--------|
| _(none)_ | | | |
<!-- WORKTREE-MAP-END -->

### Strict Rules

1. Never switch branches inside a worktree.
2. Never commit on orphaned branches without explicit instruction.
3. If worktrees exist above, do NOT make feature changes in this main repo directory.
4. Do not create worktrees yourself — tell user to run `wt <name>`.
5. If unsure which worktree you are in, ask.
```

The table between the markers is auto-regenerated by `wt` and `wt cleanup`.

### Dev Servers

Run `dev init` in projects that use dev servers:

```bash
cd my-project
dev init        # auto-detects vite, convex, next.js
```

---

## Typical Workflow

```bash
cd my-project

# Start a feature with dev servers
dev auth-feature
# → Creates worktree, allocates ports, prints Ghostty split instructions
# → Tab renamed to "wt: auth-feature"
# → First split command copied to clipboard

# In Ghostty splits, start dev servers with the printed commands
# In the main split, launch Claude
claude

# --- Meanwhile, in another Ghostty tab ---

# Start another feature (gets different ports automatically)
dev billing-ui

# Check what's running across all worktrees
dev ps

# When done, merge and clean up
wt merge auth-feature

# Or use branch management for lighter-weight work
br quick-fix
# ... work ...
br pr              # push + create PR targeting base
br pr-done         # clean up after merge
```

## Compatibility

- Shell: bash and zsh
- Terminal: Ghostty (tab renaming, split keybindings in instructions)
- Works with the [superpowers `using-git-worktrees` skill](https://github.com/anthropics/claude-code-plugins)
- Worktrees created by other tools show in `wt list` via `git worktree list`

## License

MIT
