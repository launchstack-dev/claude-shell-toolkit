#!/usr/bin/env bash
# dev.sh — Dev Workspace Launcher for Claude Code
# Layers dev server management on top of wt.sh (does not modify wt.sh)
# Source from ~/.zshrc (after wt.sh). Provides: dev, dev-init, dev-ps, dev-stop, dev-help
#
# Requires: jq, wt.sh sourced first

# ─── Dependency Check ────────────────────────────────────────────────────────

if ! type _wt_ensure_git_root &>/dev/null; then
  echo "dev.sh: Warning — wt.sh must be sourced before dev.sh" >&2
fi

# ─── Internal Helpers ────────────────────────────────────────────────────────

_dev_set_tab_title() {
  # Set Ghostty tab title via OSC escape sequence
  local title="$1"
  printf '\033]2;%s\007' "$title"
}

_dev_find_devrc() {
  # Walk up from cwd to find .devrc.json, returns path or fails
  local dir="$PWD"
  while [ "$dir" != "/" ]; do
    if [ -f "$dir/.devrc.json" ]; then
      echo "$dir/.devrc.json"
      return 0
    fi
    dir="$(dirname "$dir")"
  done
  return 1
}

_dev_port_offset() {
  # Takes worktree name, returns deterministic offset 1-99 via cksum (never 0)
  local name="$1"
  local hash
  hash=$(printf '%s' "$name" | cksum | awk '{print $1}')
  echo $(( (hash % 99) + 1 ))
}

_dev_alloc_ports() {
  # Reads .devrc.json, computes ports for a worktree name, checks collisions
  # Args: devrc_path worktree_name repo_root
  # Outputs JSON: {"service_name": port, ...}
  local devrc="$1" wt_name="$2" repo_root="$3"

  # Main repo gets default ports directly
  if [ -z "$wt_name" ] || [ "$wt_name" = "__main__" ]; then
    jq '.services | map({(.name): .port}) | add' "$devrc"
    return 0
  fi

  local offset
  offset=$(_dev_port_offset "$wt_name")

  # Collect ports already allocated by other worktrees
  local existing_ports=""
  if [ -d "$repo_root/.worktrees" ]; then
    while IFS= read -r pf; do
      [ -f "$pf" ] || continue
      # Skip current worktree's own ports file
      local pf_wt
      pf_wt=$(basename "$(dirname "$pf")")
      [ "$pf_wt" = "$wt_name" ] && continue
      existing_ports="$existing_ports $(jq -r 'values[]' "$pf" 2>/dev/null)"
    done < <(find "$repo_root/.worktrees" -maxdepth 2 -name ".ports.json" 2>/dev/null)
  fi
  # Default ports are reserved for main repo
  existing_ports="$existing_ports $(jq -r '.services[].port' "$devrc")"

  local attempt=0
  while [ "$attempt" -lt 99 ]; do
    local collision=false result="{}"

    while IFS= read -r svc; do
      local sname sport computed main_only
      sname=$(echo "$svc" | jq -r '.name')
      sport=$(echo "$svc" | jq -r '.port')
      main_only=$(echo "$svc" | jq -r '.main_only // false')

      # Skip main_only services in worktrees
      [ "$main_only" = "true" ] && continue

      computed=$((sport + offset + attempt))

      # Check against known allocated ports
      if echo " $existing_ports " | grep -qw "$computed"; then
        collision=true; break
      fi
      # Check if port is bound by any process
      if lsof -i :"$computed" -sTCP:LISTEN &>/dev/null; then
        collision=true; break
      fi

      result=$(echo "$result" | jq --arg n "$sname" --argjson p "$computed" '. + {($n): $p}')
    done < <(jq -c '.services[]' "$devrc")

    if [ "$collision" = false ]; then
      echo "$result"
      return 0
    fi
    attempt=$((attempt + 1))
  done

  echo "Error: Could not allocate ports after 99 attempts" >&2
  return 1
}

_dev_print_workspace() {
  # Prints the Ghostty split instructions box for given ports/commands
  # Args: worktree_path ports_json devrc_path is_main
  local wt_path="$1" ports_json="$2" devrc="$3" is_main="${4:-false}"

  echo ""
  echo "── Workspace Setup ─────────────────────────────────────────────────"

  local first_cmd="" port_summary=""
  while IFS= read -r svc; do
    local sname scmd allocated final_cmd main_only
    sname=$(echo "$svc" | jq -r '.name')
    scmd=$(echo "$svc" | jq -r '.cmd')
    main_only=$(echo "$svc" | jq -r '.main_only // false')

    # Skip main_only services in worktrees
    if [ "$is_main" != "true" ] && [ "$main_only" = "true" ]; then
      continue
    fi

    allocated=$(echo "$ports_json" | jq -r --arg n "$sname" '.[$n]')
    final_cmd="${scmd//\{port\}/$allocated}"

    if [ -z "$first_cmd" ]; then
      echo "  Cmd+D (split right), then run:"
      first_cmd="$final_cmd"
    else
      echo ""
      echo "  Cmd+Shift+D (split down), then run:"
    fi
    echo "    $final_cmd"

    [ -n "$port_summary" ] && port_summary="$port_summary · "
    port_summary="${port_summary}${sname} :${allocated}"
  done < <(jq -c '.services[]' "$devrc")

  echo ""
  echo "  Cmd+[ to return here, then run:"
  echo "    claude"
  echo ""
  echo "  Ports: $port_summary"

  if [ -n "$first_cmd" ] && command -v pbcopy &>/dev/null; then
    printf '%s' "$first_cmd" | pbcopy
    echo "  (first command copied to clipboard)"
  fi

  echo "─────────────────────────────────────────────────────────────────────"
  echo ""
}

_dev_find_procs() {
  # Finds running processes matching services from .devrc.json
  # Args: devrc_path repo_root
  # Outputs lines: PID SERVICE PORT CWD SOURCE
  local devrc="$1" repo_root="$2"
  local seen_pids=""

  # Port-based detection: default ports (main repo)
  while IFS= read -r svc; do
    local sname sport pid
    sname=$(echo "$svc" | jq -r '.name')
    sport=$(echo "$svc" | jq -r '.port')
    pid=$(lsof -i :"$sport" -sTCP:LISTEN -t 2>/dev/null | head -1)
    if [ -n "$pid" ]; then
      local cwd
      cwd=$(lsof -p "$pid" -d cwd -Fn 2>/dev/null | grep '^n' | head -1 | sed 's/^n//')
      echo "$pid $sname $sport ${cwd:--} __main__"
      seen_pids="$seen_pids $pid"
    fi
  done < <(jq -c '.services[]' "$devrc")

  # Port-based detection: worktree ports from .ports.json files
  if [ -d "$repo_root/.worktrees" ]; then
    while IFS= read -r pf; do
      [ -f "$pf" ] || continue
      local wt_name
      wt_name=$(basename "$(dirname "$pf")")

      while IFS= read -r key; do
        local port pid
        port=$(jq -r --arg k "$key" '.[$k]' "$pf")
        pid=$(lsof -i :"$port" -sTCP:LISTEN -t 2>/dev/null | head -1)
        if [ -n "$pid" ] && ! echo " $seen_pids " | grep -qw "$pid"; then
          local cwd
          cwd=$(lsof -p "$pid" -d cwd -Fn 2>/dev/null | grep '^n' | head -1 | sed 's/^n//')
          echo "$pid $key $port ${cwd:--} $wt_name"
          seen_pids="$seen_pids $pid"
        fi
      done < <(jq -r 'keys[]' "$pf")
    done < <(find "$repo_root/.worktrees" -maxdepth 2 -name ".ports.json" 2>/dev/null)
  fi

  # Name-based sweep for orphans (processes in deleted worktrees)
  while IFS= read -r svc; do
    local sname
    sname=$(echo "$svc" | jq -r '.name')

    while IFS= read -r pid; do
      [ -z "$pid" ] && continue
      echo " $seen_pids " | grep -qw "$pid" && continue

      local cwd
      cwd=$(lsof -p "$pid" -d cwd -Fn 2>/dev/null | grep '^n' | head -1 | sed 's/^n//')
      [ -z "$cwd" ] && continue

      # Only flag if cwd was inside a .worktrees/ dir that no longer exists
      if [[ "$cwd" == *"/.worktrees/"* ]]; then
        local wt_check
        wt_check=$(echo "$cwd" | sed 's|^\(.*/.worktrees/[^/]*\).*|\1|')
        if [ ! -d "$wt_check" ]; then
          local port
          port=$(lsof -p "$pid" -i -sTCP:LISTEN -Fn 2>/dev/null | grep -oE ':[0-9]+' | head -1 | tr -d ':')
          echo "$pid $sname ${port:--} $cwd __orphan__"
          seen_pids="$seen_pids $pid"
        fi
      fi
    done < <(pgrep -f "$sname" 2>/dev/null)
  done < <(jq -c '.services[]' "$devrc")
}

# ─── Public Commands ─────────────────────────────────────────────────────────

dev() {
  local name="$1" base="$2"
  _wt_check_jq || return 1

  # Find .devrc.json
  local devrc
  devrc=$(_dev_find_devrc)
  if [ $? -ne 0 ]; then
    echo "No .devrc.json found. Run dev-init to set up."
    return 1
  fi

  local repo_root
  repo_root="$(_wt_ensure_git_root)" || return 1

  local worktree_path="" wt_name="" is_main=false

  if [ -n "$name" ]; then
    local target="$repo_root/.worktrees/$name"
    if [ -d "$target" ]; then
      # Existing worktree — cd into it
      worktree_path="$target"
      wt_name="$name"
      cd "$worktree_path" || return 1
      echo "Entered worktree '$name' at $worktree_path"
    else
      # Create new worktree via wt (wt requires main repo cwd)
      local saved_dir="$PWD"
      cd "$repo_root" || return 1
      wt "$name" ${base:+"$base"} || { cd "$saved_dir" 2>/dev/null; return 1; }
      # wt already cd'd into the new worktree
      worktree_path="$repo_root/.worktrees/$name"
      wt_name="$name"
    fi
  else
    # No args — detect context
    local current_toplevel
    current_toplevel="$(git rev-parse --show-toplevel)"
    if [ "$current_toplevel" != "$repo_root" ]; then
      # Inside a worktree
      worktree_path="$current_toplevel"
      wt_name="$(basename "$worktree_path")"
    else
      # In main repo
      is_main=true
      worktree_path="$repo_root"
      wt_name="__main__"
    fi
  fi

  # Reuse existing .ports.json if present, otherwise compute fresh
  local ports_json
  if [ "$is_main" = false ] && [ -f "$worktree_path/.ports.json" ]; then
    ports_json=$(cat "$worktree_path/.ports.json")
  else
    ports_json=$(_dev_alloc_ports "$devrc" "$wt_name" "$repo_root") || return 1
    # Write .ports.json sidecar (skip for main repo)
    if [ "$is_main" = false ] && [ -d "$worktree_path" ]; then
      local tmp_ports
      tmp_ports="$(mktemp)"
      echo "$ports_json" | jq '.' > "$tmp_ports"
      mv "$tmp_ports" "$worktree_path/.ports.json"
    fi
  fi

  # Set Ghostty tab title
  if [ "$is_main" = true ]; then
    local project
    project="$(basename "$repo_root")"
    _dev_set_tab_title "$project"
  else
    _dev_set_tab_title "wt: $wt_name"
  fi

  # Print header
  if [ "$is_main" = true ]; then
    echo ""
    echo "Main repo at: $repo_root"
  else
    echo ""
    echo "Worktree '$wt_name' ready at: $worktree_path"
  fi

  _dev_print_workspace "$worktree_path" "$ports_json" "$devrc" "$is_main"
}

dev-init() {
  _wt_check_jq || return 1

  local repo_root
  repo_root="$(_wt_ensure_git_root)" || return 1

  if [ -f "$repo_root/.devrc.json" ]; then
    echo "A .devrc.json already exists at $repo_root/.devrc.json"
    _wt_prompt "Overwrite? [y/N]"
    [[ ! "$REPLY" =~ ^[Yy]$ ]] && { echo "Aborted."; return 0; }
  fi

  echo "Detecting dev servers..."
  local services="[]"

  # Detect Vite
  local has_vite=false
  for f in "$repo_root"/vite.config.*; do
    [ -f "$f" ] && { has_vite=true; break; }
  done
  if [ "$has_vite" = false ] && [ -f "$repo_root/package.json" ]; then
    jq -e '.devDependencies.vite // .dependencies.vite' "$repo_root/package.json" &>/dev/null && has_vite=true
  fi
  if [ "$has_vite" = true ]; then
    echo "  Detected: vite (port 5173)"
    services=$(echo "$services" | jq '. + [{"name":"vite","cmd":"npx vite --port {port}","port":5173}]')
  fi

  # Detect Convex
  local has_convex=false
  [ -d "$repo_root/convex" ] && has_convex=true
  if [ "$has_convex" = false ] && [ -f "$repo_root/package.json" ]; then
    jq -e '.devDependencies.convex // .dependencies.convex' "$repo_root/package.json" &>/dev/null && has_convex=true
  fi
  if [ "$has_convex" = true ]; then
    echo "  Detected: convex (port 3210, main only)"
    services=$(echo "$services" | jq '. + [{"name":"convex","cmd":"npx convex dev --admin-port {port}","port":3210,"main_only":true}]')
  fi

  # Detect Next.js
  local has_next=false
  for f in "$repo_root"/next.config.*; do
    [ -f "$f" ] && { has_next=true; break; }
  done
  if [ "$has_next" = true ]; then
    echo "  Detected: next (port 3000)"
    services=$(echo "$services" | jq '. + [{"name":"next","cmd":"npx next dev --port {port}","port":3000}]')
  fi

  local count
  count=$(echo "$services" | jq 'length')
  if [ "$count" -eq 0 ]; then
    echo "No dev servers detected automatically."
    echo ""
    echo "Create .devrc.json manually with this template:"
    echo ""
    cat <<'TEMPLATE'
{
  "services": [
    {
      "name": "your-server",
      "cmd": "your-command --port {port}",
      "port": 8080
    }
  ]
}
TEMPLATE
    return 0
  fi

  local config
  config=$(jq -n --argjson s "$services" '{"services": $s}')

  echo ""
  echo "Proposed .devrc.json:"
  echo "$config" | jq '.'
  echo ""

  _wt_prompt "Write to $repo_root/.devrc.json? [Y/n]"
  [[ "$REPLY" =~ ^[Nn]$ ]] && { echo "Aborted."; return 0; }

  local tmp_devrc
  tmp_devrc="$(mktemp)"
  echo "$config" | jq '.' > "$tmp_devrc"
  mv "$tmp_devrc" "$repo_root/.devrc.json"
  echo "Wrote $repo_root/.devrc.json"
}

dev-ps() {
  _wt_check_jq || return 1

  local devrc
  devrc=$(_dev_find_devrc)
  if [ $? -ne 0 ]; then
    echo "No .devrc.json found. Run dev-init to set up."
    return 1
  fi

  local repo_root
  repo_root="$(_wt_ensure_git_root)" || return 1

  echo "Scanning for dev server processes..."
  echo ""

  local main_procs="" wt_procs="" orphan_procs=""

  while IFS= read -r line; do
    [ -z "$line" ] && continue
    local pid sname port cwd source
    pid=$(echo "$line" | awk '{print $1}')
    sname=$(echo "$line" | awk '{print $2}')
    port=$(echo "$line" | awk '{print $3}')
    cwd=$(echo "$line" | awk '{print $4}')
    source=$(echo "$line" | awk '{print $5}')

    if [ "$source" = "__main__" ]; then
      main_procs="${main_procs}  PID ${pid}  ${sname}  :${port}  (${cwd})\n"
    elif [ "$source" = "__orphan__" ] || [ "$source" = "__unknown__" ]; then
      orphan_procs="${orphan_procs}${pid} ${sname} ${port} ${cwd}\n"
    else
      wt_procs="${wt_procs}  PID ${pid}  ${sname}  :${port}  (.worktrees/${source})\n"
    fi
  done < <(_dev_find_procs "$devrc" "$repo_root")

  if [ -n "$main_procs" ]; then
    echo "Main repo:"
    printf "$main_procs"
    echo ""
  fi

  if [ -n "$wt_procs" ]; then
    echo "Active worktrees:"
    printf "$wt_procs"
    echo ""
  fi

  if [ -n "$orphan_procs" ]; then
    echo "Orphaned processes:"
    while IFS= read -r orphan; do
      [ -z "$orphan" ] && continue
      local opid osname oport ocwd
      opid=$(echo "$orphan" | awk '{print $1}')
      osname=$(echo "$orphan" | awk '{print $2}')
      oport=$(echo "$orphan" | awk '{print $3}')
      ocwd=$(echo "$orphan" | awk '{print $4}')
      echo "  PID ${opid}  ${osname}  :${oport}  (cwd: ${ocwd})"
      _wt_prompt "  Kill PID $opid ($osname on :$oport)? [y/N]"
      [[ "$REPLY" =~ ^[Yy]$ ]] && { kill "$opid" 2>/dev/null && echo "  Killed." || echo "  Failed."; }
    done < <(printf "$orphan_procs")
    echo ""
  fi

  if [ -z "$main_procs" ] && [ -z "$wt_procs" ] && [ -z "$orphan_procs" ]; then
    echo "No dev server processes found."
  fi
}

dev-stop() {
  _wt_check_jq || return 1

  local name="$1"

  local devrc
  devrc=$(_dev_find_devrc)
  if [ $? -ne 0 ]; then
    echo "No .devrc.json found."
    return 1
  fi

  local repo_root
  repo_root="$(_wt_ensure_git_root)" || return 1

  local target_path
  if [ -n "$name" ]; then
    target_path="$repo_root/.worktrees/$name"
    if [ ! -d "$target_path" ]; then
      echo "Error: Worktree '$name' not found." >&2
      return 1
    fi
  else
    # Auto-detect from cwd
    target_path="$(git rev-parse --show-toplevel)"
  fi

  echo "Stopping dev servers for: $target_path"
  echo ""

  local found=false

  # Check ports from .ports.json if available
  if [ -f "$target_path/.ports.json" ]; then
    while IFS= read -r key; do
      local port pid
      port=$(jq -r --arg k "$key" '.[$k]' "$target_path/.ports.json")
      pid=$(lsof -i :"$port" -sTCP:LISTEN -t 2>/dev/null | head -1)
      if [ -n "$pid" ]; then
        found=true
        _wt_prompt "Kill $key (PID $pid, port :$port)? [y/N]"
        [[ "$REPLY" =~ ^[Yy]$ ]] && { kill "$pid" 2>/dev/null && echo "  Killed $key (PID $pid)." || echo "  Failed."; }
      fi
    done < <(jq -r 'keys[]' "$target_path/.ports.json")
  fi

  # Fallback: check default ports if targeting main repo
  if [ "$found" = false ] && [ "$target_path" = "$repo_root" ]; then
    while IFS= read -r svc; do
      local sname sport pid
      sname=$(echo "$svc" | jq -r '.name')
      sport=$(echo "$svc" | jq -r '.port')
      pid=$(lsof -i :"$sport" -sTCP:LISTEN -t 2>/dev/null | head -1)
      if [ -n "$pid" ]; then
        found=true
        _wt_prompt "Kill $sname (PID $pid, port :$sport)? [y/N]"
        [[ "$REPLY" =~ ^[Yy]$ ]] && { kill "$pid" 2>/dev/null && echo "  Killed $sname (PID $pid)." || echo "  Failed."; }
      fi
    done < <(jq -c '.services[]' "$devrc")
  fi

  [ "$found" = false ] && echo "No dev server processes found for $target_path."
}

dev-help() {
  cat <<'HELP'
Dev Workspace Launcher for Claude Code
=======================================

Commands:
  dev [name] [base]      Create/enter worktree + show workspace setup with ports
                          No args in main repo → default ports
                          No args in worktree → worktree ports

  dev-init               Scaffold .devrc.json (auto-detects vite, convex, next)

  dev-ps                 Show running dev servers, flag orphans, prompt to kill

  dev-stop [name]        Kill dev servers for a worktree (auto-detects from cwd)

  dev-help               Show this help

Port allocation:
  Main repo always gets default ports from .devrc.json
  Worktrees get base port + deterministic offset (1-99) via name hash
  Collisions with existing worktrees or bound ports are auto-resolved

Config file: .devrc.json (project root, next to package.json)
  {
    "services": [
      {"name": "vite", "cmd": "npx vite --port {port}", "port": 5173},
      {"name": "convex", "cmd": "npx convex dev --admin-port {port}", "port": 3210, "main_only": true}
    ]
  }

  main_only: true — service only runs in main repo, skipped in worktrees
                     (use for services like Convex that share a cloud backend)

Port file: .ports.json (in each worktree, separate from .worktree.json)
  Written automatically by dev, read by dev-ps and dev-stop

Requirements: jq, wt.sh (sourced before dev.sh)
HELP
}
