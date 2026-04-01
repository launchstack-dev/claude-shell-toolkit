#!/usr/bin/env bash
# dev.sh — Dev Workspace Launcher for Claude Code
# Layers dev server management on top of wt.sh (does not modify wt.sh)
# Source from ~/.zshrc (after wt.sh). Provides: dev (init, start, stop, ps, status, mprocs, help)
# Legacy aliases: dev-init, dev-start, dev-stop, dev-ps, dev-status, dev-mprocs, dev-help
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

_dev_detect_context() {
  # Detects whether we're in main repo or a worktree, optionally by name.
  # Args: repo_root [name]
  # Outputs tab-delimited: worktree_path\twt_name\tis_main
  # If name is given, looks up that worktree (errors if not found).
  # If name is omitted, auto-detects from cwd.
  local repo_root="$1" name="$2"
  if [ -n "$name" ]; then
    local target="$repo_root/.worktrees/$name"
    if [ ! -d "$target" ]; then
      echo "Error: Worktree '$name' not found." >&2
      return 1
    fi
    printf '%s\t%s\t%s' "$target" "$name" "false"
  else
    local current_toplevel
    current_toplevel="$(git rev-parse --show-toplevel 2>/dev/null)"
    if [ -z "$current_toplevel" ]; then
      echo "Error: Not inside a git repository." >&2
      return 1
    fi
    if [ "$current_toplevel" != "$repo_root" ]; then
      printf '%s\t%s\t%s' "$current_toplevel" "$(basename "$current_toplevel")" "false"
    else
      printf '%s\t%s\t%s' "$repo_root" "__main__" "true"
    fi
  fi
}

_dev_resolve_ports() {
  # Resolves port allocations for a worktree/main context.
  # Args: devrc repo_root worktree_path is_main
  # Outputs: ports JSON on stdout
  local devrc="$1" repo_root="$2" worktree_path="$3" is_main="$4"
  if [ "$is_main" = "false" ] && [ -f "$worktree_path/.ports.json" ]; then
    cat "$worktree_path/.ports.json"
  elif [ "$is_main" = "true" ]; then
    local result
    result="$(_dev_alloc_ports "$devrc" "__main__" "$repo_root")" || return 1
    echo "$result"
  else
    # No .ports.json yet — allocate ports now (with lock to prevent races)
    local wt_name
    wt_name="$(basename "$worktree_path")"
    mkdir -p "$repo_root/.worktrees"
    local port_lockdir="$repo_root/.worktrees/.ports.lock"
    _wt_acquire_lock "$port_lockdir" 5 || return 1
    local result
    result="$(_dev_alloc_ports "$devrc" "$wt_name" "$repo_root")" || { _wt_release_lock "$port_lockdir"; return 1; }
    # Write .ports.json for future use
    if [ -d "$worktree_path" ]; then
      local tmp_ports
      tmp_ports="$(mktemp)"
      echo "$result" | jq '.' > "$tmp_ports"
      mv "$tmp_ports" "$worktree_path/.ports.json"
    fi
    _wt_release_lock "$port_lockdir"
    echo "$result"
  fi
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

_dev_format_uptime() {
  # Formats an ISO timestamp as a human-readable uptime string.
  # Args: started_timestamp (e.g. 2024-01-15T10:30:00Z)
  local started="$1"
  [ -z "$started" ] || [ "$started" = "null" ] && return
  local start_epoch now_epoch diff
  start_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$started" +%s 2>/dev/null) || return
  now_epoch=$(date +%s)
  diff=$((now_epoch - start_epoch))
  if [ "$diff" -lt 60 ]; then
    echo "${diff}s"
  elif [ "$diff" -lt 3600 ]; then
    echo "$((diff / 60))m"
  elif [ "$diff" -lt 86400 ]; then
    echo "$((diff / 3600))h $((diff % 3600 / 60))m"
  else
    echo "$((diff / 86400))d $((diff % 86400 / 3600))h"
  fi
}

_dev_status_for_path() {
  # Prints status rows for all services in a worktree or main repo.
  # Args: label target_path devrc
  # Returns 0 if any entries were printed, 1 otherwise.
  local label="$1" target_path="$2" devrc="$3"
  local pid_dir="$target_path/.pids"
  local ports_file="$target_path/.ports.json"
  local printed=false

  # Collect known services from .ports.json or devrc
  local services_json
  if [ -f "$ports_file" ]; then
    services_json=$(jq -r 'keys[]' "$ports_file" 2>/dev/null)
    if [ $? -ne 0 ]; then
      echo "  Warning: $ports_file contains invalid JSON" >&2
      return 1
    fi
  elif [ "$label" = "__main__" ]; then
    services_json=$(jq -r '.services[].name' "$devrc")
  else
    return 1
  fi

  while IFS= read -r sname; do
    [ -z "$sname" ] && continue
    printed=true

    local port="-" pid="-" status="stopped" uptime="-"

    # Get port
    if [ -f "$ports_file" ]; then
      port=$(jq -r --arg n "$sname" '.[$n] // "-"' "$ports_file" 2>/dev/null)
    fi
    if [ "$port" = "-" ] && [ "$label" = "__main__" ]; then
      port=$(jq -r --arg n "$sname" '.services[] | select(.name == $n) | .port' "$devrc" 2>/dev/null)
    fi

    # Check PID file first
    if [ -d "$pid_dir" ] && [ -f "$pid_dir/$sname.pid" ]; then
      if _dev_check_pid "$pid_dir" "$sname"; then
        pid=$(jq -r '.pid' "$pid_dir/$sname.pid" 2>/dev/null)
        status="running"
        local started
        started=$(jq -r '.started' "$pid_dir/$sname.pid" 2>/dev/null)
        uptime=$(_dev_format_uptime "$started")
        [ -z "$uptime" ] && uptime="-"
      fi
    fi

    # Fallback: port-based detection if no PID file
    if [ "$status" = "stopped" ] && [ "$port" != "-" ] && [ "$port" != "null" ]; then
      local port_pid
      port_pid=$(lsof -i :"$port" -sTCP:LISTEN -t 2>/dev/null | head -1)
      if [ -n "$port_pid" ]; then
        pid="$port_pid"
        status="running*"
      fi
    fi

    printf "%-20s %-12s %-7s %-8s %-10s %s\n" "$label" "$sname" "$port" "$pid" "$status" "$uptime"
  done <<< "$services_json"

  [ "$printed" = true ]
}

_dev_scan_pids() {
  # Scans a .pids/ directory and outputs live entries as tab-delimited lines.
  # Args: pid_dir target_path label
  # Outputs: PID\tSERVICE\tPORT\tPATH\tLABEL  (one per live service)
  local pid_dir="$1" target_path="$2" label="$3"
  [ -d "$pid_dir" ] || return 0
  [ -n "$(find "$pid_dir" -maxdepth 1 -name '*.pid' -print -quit 2>/dev/null)" ] || return 0
  for pidfile in "$pid_dir"/*.pid; do
    [ -f "$pidfile" ] || continue
    local sname srv_pid srv_port
    sname="$(basename "$pidfile" .pid)"
    if _dev_check_pid "$pid_dir" "$sname"; then
      srv_pid="$(jq -r '.pid' "$pidfile" 2>/dev/null)"
      srv_port="$(jq -r '.port' "$pidfile" 2>/dev/null)"
      echo "$srv_pid	$sname	$srv_port	$target_path	$label"
    fi
  done
}

_dev_find_procs() {
  # Finds running processes matching services from .devrc.json
  # Args: devrc_path repo_root
  # Outputs lines: PID SERVICE PORT CWD SOURCE
  local devrc="$1" repo_root="$2"
  local seen_pids=""

  # PID-file scan: main repo + worktrees
  local pid_line
  while IFS= read -r pid_line; do
    [ -z "$pid_line" ] && continue
    echo "$pid_line"
    local pid_from_line
    pid_from_line="$(echo "$pid_line" | cut -f1)"
    seen_pids="$seen_pids $pid_from_line"
  done < <(
    _dev_scan_pids "$repo_root/.pids" "$repo_root" "__main__"
    if [ -d "$repo_root/.worktrees" ]; then
      for wt_pid_dir in "$repo_root/.worktrees"/*/.pids; do
        [ -d "$wt_pid_dir" ] || continue
        local wt_path wt_name
        wt_path="$(dirname "$wt_pid_dir")"
        wt_name="$(basename "$wt_path")"
        _dev_scan_pids "$wt_pid_dir" "$wt_path" "$wt_name"
      done
    fi
  )

  # Port-based detection: default ports (main repo)
  while IFS= read -r svc; do
    local sname sport pid
    sname=$(echo "$svc" | jq -r '.name')
    sport=$(echo "$svc" | jq -r '.port')
    pid=$(lsof -i :"$sport" -sTCP:LISTEN -t 2>/dev/null | head -1)
    if [ -n "$pid" ] && ! echo " $seen_pids " | grep -qw "$pid"; then
      local cwd
      cwd=$(lsof -p "$pid" -d cwd -Fn 2>/dev/null | grep '^n' | head -1 | sed 's/^n//')
      echo "$pid	$sname	$sport	${cwd:--}	__main__"
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
          echo "$pid	$key	$port	${cwd:--}	$wt_name"
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
          echo "$pid	$sname	${port:--}	$cwd	__orphan__"
          seen_pids="$seen_pids $pid"
        fi
      fi
    done < <(pgrep -f "(^|/)$sname(\\s|$)" 2>/dev/null)
  done < <(jq -c '.services[]' "$devrc")
}

# ─── PID File Management ────────────────────────────────────────────────────

_dev_pid_dir() {
  # Returns the .pids/ directory for a given path (worktree or repo root).
  # Creates the directory if it does not exist.
  # Args: [target_path]  (defaults to git toplevel)
  local target="${1:-$(git rev-parse --show-toplevel 2>/dev/null)}"
  [ -z "$target" ] && return 1
  local dir="$target/.pids"
  [ -d "$dir" ] || mkdir -p "$dir"
  echo "$dir"
}

_dev_write_pid() {
  # Writes a PID file for a service.
  # Args: pid_dir service_name pid port cmd
  local pid_dir="$1" sname="$2" pid="$3" port="$4" cmd="$5"
  local tmp
  tmp="$(mktemp)"
  if ! jq -n --argjson pid "$pid" --argjson port "$port" --arg cmd "$cmd" \
    --arg started "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{"pid":$pid,"port":$port,"cmd":$cmd,"started":$started}' > "$tmp"; then
    echo "  Error: Failed to write PID file for $sname" >&2
    rm -f "$tmp"
    return 1
  fi
  mv "$tmp" "$pid_dir/$sname.pid"
}

_dev_check_pid() {
  # Validates a PID file: process alive AND owns the port.
  # Removes stale PID files. Returns 0=alive, 1=stale/missing.
  # Args: pid_dir service_name
  local pid_dir="$1" sname="$2"
  local pidfile="$pid_dir/$sname.pid"
  [ -f "$pidfile" ] || return 1

  local srv_pid srv_port
  srv_pid="$(jq -r '.pid' "$pidfile" 2>/dev/null)"
  srv_port="$(jq -r '.port' "$pidfile" 2>/dev/null)"

  # Detect corrupt/invalid PID file
  if [ -z "$srv_pid" ] || [ "$srv_pid" = "null" ]; then
    echo "  Warning: Corrupt PID file removed: $pidfile" >&2
    rm -f "$pidfile"
    return 1
  fi

  # Check process is alive
  if ! kill -0 "$srv_pid" 2>/dev/null; then
    rm -f "$pidfile"
    return 1
  fi

  # Verify the PID owns the port (guards against PID recycling)
  if [ -n "$srv_port" ] && [ "$srv_port" != "null" ]; then
    local port_owner
    port_owner="$(lsof -i :"$srv_port" -sTCP:LISTEN -t 2>/dev/null | head -1)"
    if [ -n "$port_owner" ] && [ "$port_owner" != "$srv_pid" ]; then
      rm -f "$pidfile"
      return 1
    fi
  fi

  return 0
}

_dev_kill_pid() {
  # Kills a service by PID file. SIGTERM, wait up to 3s, SIGKILL if needed.
  # Removes the PID file afterward.
  # Args: pid_dir service_name [--force]
  local pid_dir="$1" sname="$2" force="$3"
  local pidfile="$pid_dir/$sname.pid"
  [ -f "$pidfile" ] || return 1

  local srv_pid srv_port
  srv_pid="$(jq -r '.pid' "$pidfile" 2>/dev/null)"
  srv_port="$(jq -r '.port' "$pidfile" 2>/dev/null)"

  if [ -z "$srv_pid" ] || ! kill -0 "$srv_pid" 2>/dev/null; then
    rm -f "$pidfile"
    echo "  $sname: stale PID file removed (process already exited)"
    return 0
  fi

  if [ "$force" != "--force" ]; then
    _wt_prompt "  Kill $sname (PID $srv_pid, port :${srv_port:--})? [y/N]"
    if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
      echo "  Skipped."
      return 0
    fi
  fi

  if ! kill "$srv_pid" 2>/dev/null; then
    # Process may have died between check and kill, or permission denied
    if kill -0 "$srv_pid" 2>/dev/null; then
      echo "  Error: Permission denied killing $sname (PID $srv_pid)" >&2
      return 1  # Do NOT remove the PID file
    fi
    echo "  $sname (PID $srv_pid) already exited"
    rm -f "$pidfile"
    return 0
  fi

  # Wait up to 3 seconds for graceful shutdown
  local waited=0
  while [ "$waited" -lt 30 ] && kill -0 "$srv_pid" 2>/dev/null; do
    sleep 0.1
    waited=$((waited + 1))
  done

  # Force kill if still alive
  if kill -0 "$srv_pid" 2>/dev/null; then
    if ! kill -9 "$srv_pid" 2>/dev/null; then
      echo "  Error: Could not force-kill $sname (PID $srv_pid)" >&2
      return 1
    fi
    echo "  Force-killed $sname (PID $srv_pid)"
  else
    echo "  Killed $sname (PID $srv_pid)"
  fi

  rm -f "$pidfile"
  return 0
}

# ─── Public Commands ─────────────────────────────────────────────────────────

_dev_enter() {
  local name="$1" base="$2"
  _wt_check_jq || return 1

  # Find .devrc.json
  local devrc
  devrc=$(_dev_find_devrc)
  if [ $? -ne 0 ]; then
    echo "No .devrc.json found. Run dev init to set up."
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
      _wt_create "$name" ${base:+"$base"} || { cd "$saved_dir" 2>/dev/null; return 1; }
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
    # Lock around port allocation to prevent races between concurrent dev invocations
    mkdir -p "$repo_root/.worktrees"
    local port_lockdir="$repo_root/.worktrees/.ports.lock"
    _wt_acquire_lock "$port_lockdir" 5 || return 1
    ports_json=$(_dev_alloc_ports "$devrc" "$wt_name" "$repo_root") || { _wt_release_lock "$port_lockdir"; return 1; }
    # Write .ports.json sidecar (skip for main repo)
    if [ "$is_main" = false ] && [ -d "$worktree_path" ]; then
      local tmp_ports
      tmp_ports="$(mktemp)"
      echo "$ports_json" | jq '.' > "$tmp_ports"
      mv "$tmp_ports" "$worktree_path/.ports.json"
    fi
    _wt_release_lock "$port_lockdir"
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

_dev_start() {
  # Starts dev server(s) in the background with PID file tracking.
  # Args: [service_name]  (starts all if omitted)
  local target_service="$1"
  _wt_check_jq || return 1

  local devrc
  devrc=$(_dev_find_devrc)
  if [ $? -ne 0 ]; then
    echo "No .devrc.json found. Run dev init to set up."
    return 1
  fi

  local repo_root
  repo_root="$(_wt_ensure_git_root)" || return 1

  # Detect context (main repo vs worktree)
  local worktree_path wt_name is_main ctx
  ctx="$(_dev_detect_context "$repo_root")" || return 1
  IFS=$'\t' read -r worktree_path wt_name is_main <<< "$ctx"

  local ports_json
  ports_json="$(_dev_resolve_ports "$devrc" "$repo_root" "$worktree_path" "$is_main")" || return 1

  local pid_dir
  pid_dir="$(_dev_pid_dir "$worktree_path")" || return 1

  local started=0 skipped=0

  while IFS= read -r svc; do
    local sname scmd sport main_only
    sname=$(echo "$svc" | jq -r '.name')
    scmd=$(echo "$svc" | jq -r '.cmd')
    sport=$(echo "$svc" | jq -r '.port')
    main_only=$(echo "$svc" | jq -r '.main_only // false')

    # Skip main_only services in worktrees
    if [ "$is_main" != "true" ] && [ "$main_only" = "true" ]; then
      continue
    fi

    # Filter to specific service if requested
    if [ -n "$target_service" ] && [ "$sname" != "$target_service" ]; then
      continue
    fi

    # Check if already running
    if _dev_check_pid "$pid_dir" "$sname"; then
      local existing_pid
      existing_pid="$(jq -r '.pid' "$pid_dir/$sname.pid" 2>/dev/null)"
      echo "  $sname already running (PID $existing_pid)"
      skipped=$((skipped + 1))
      continue
    fi

    # Resolve port and command
    local allocated final_cmd
    allocated=$(echo "$ports_json" | jq -r --arg n "$sname" '.[$n]')
    if [ -z "$allocated" ] || [ "$allocated" = "null" ]; then
      allocated="$sport"
    fi
    final_cmd="${scmd//\{port\}/$allocated}"

    # Launch in background (printf %q safely escapes the path for shell evaluation)
    local safe_path
    safe_path="$(printf '%q' "$worktree_path")"
    nohup bash -c "cd $safe_path && $final_cmd" > "$pid_dir/$sname.log" 2>&1 &
    local bg_pid=$!

    # Brief verify — wait up to 2 seconds for process to stabilize
    local waited=0
    while [ "$waited" -lt 20 ]; do
      if ! kill -0 "$bg_pid" 2>/dev/null; then
        echo "  $sname failed to start. Check $pid_dir/$sname.log" >&2
        break
      fi
      # Check if port is bound yet
      if lsof -i :"$allocated" -sTCP:LISTEN &>/dev/null; then
        break
      fi
      sleep 0.1
      waited=$((waited + 1))
    done

    if kill -0 "$bg_pid" 2>/dev/null; then
      _dev_write_pid "$pid_dir" "$sname" "$bg_pid" "$allocated" "$final_cmd"
      echo "  Started $sname (PID $bg_pid) on :$allocated"
      started=$((started + 1))
    else
      echo "  $sname failed to start. Check $pid_dir/$sname.log" >&2
    fi
  done < <(jq -c '.services[]' "$devrc")

  if [ -n "$target_service" ] && [ "$started" -eq 0 ] && [ "$skipped" -eq 0 ]; then
    echo "Error: Service '$target_service' not found in .devrc.json" >&2
    return 1
  fi

  echo ""
  echo "Started $started service(s)."
  [ "$skipped" -gt 0 ] && echo "Skipped $skipped already running."
}

_dev_init() {
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
  for ext in js ts mjs mts cjs; do
    [ -f "$repo_root/vite.config.$ext" ] && { has_vite=true; break; }
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
  for ext in js ts mjs mts cjs; do
    [ -f "$repo_root/next.config.$ext" ] && { has_next=true; break; }
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

_dev_ps() {
  _wt_check_jq || return 1

  local devrc
  devrc=$(_dev_find_devrc)
  if [ $? -ne 0 ]; then
    echo "No .devrc.json found. Run dev init to set up."
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
    IFS=$'\t' read -r pid sname port cwd source <<< "$line"

    if [ "$source" = "__main__" ]; then
      main_procs="${main_procs}  PID ${pid}  ${sname}  :${port}  (${cwd})\n"
    elif [ "$source" = "__orphan__" ] || [ "$source" = "__unknown__" ]; then
      orphan_procs="${orphan_procs}${pid}	${sname}	${port}	${cwd}\n"
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
      IFS=$'\t' read -r opid osname oport ocwd <<< "$orphan"
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

_dev_stop() {
  _wt_check_jq || return 1

  # Parse args: [name] [--force]
  local name="" force=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --force) force="--force"; shift ;;
      *)       name="$1"; shift ;;
    esac
  done

  local devrc
  devrc=$(_dev_find_devrc)
  if [ $? -ne 0 ]; then
    [ "$force" != "--force" ] && echo "No .devrc.json found."
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
    target_path="$(git rev-parse --show-toplevel 2>/dev/null)"
    if [ -z "$target_path" ]; then
      echo "Error: Not inside a git repository. Specify a worktree name." >&2
      return 1
    fi
  fi

  [ "$force" != "--force" ] && echo "Stopping dev servers for: $target_path" && echo ""

  local found=false killed_services="" kill_errors=0

  # First pass: PID-file-based kill (reliable, fast)
  local pid_dir="$target_path/.pids"
  if [ -d "$pid_dir" ] && [ -n "$(find "$pid_dir" -maxdepth 1 -name '*.pid' -print -quit 2>/dev/null)" ]; then
    for pidfile in "$pid_dir"/*.pid; do
      [ -f "$pidfile" ] || continue
      local sname
      sname="$(basename "$pidfile" .pid)"
      found=true
      _dev_kill_pid "$pid_dir" "$sname" "$force" || kill_errors=$((kill_errors + 1))
      killed_services="$killed_services $sname"
    done
  fi

  # Second pass (fallback): port-based lsof check for manually-started servers
  if [ -f "$target_path/.ports.json" ]; then
    while IFS= read -r key; do
      local port pid
      port=$(jq -r --arg k "$key" '.[$k]' "$target_path/.ports.json")
      pid=$(lsof -i :"$port" -sTCP:LISTEN -t 2>/dev/null | head -1)
      if [ -n "$pid" ]; then
        # Skip if we already handled this service via PID file
        echo " $killed_services " | grep -qw "$key" && continue
        found=true
        if [ "$force" = "--force" ]; then
          kill "$pid" 2>/dev/null && echo "  Killed $key (PID $pid, port :$port)" || true
        else
          _wt_prompt "  Kill $key (PID $pid, port :$port)? [y/N]"
          [[ "$REPLY" =~ ^[Yy]$ ]] && { kill "$pid" 2>/dev/null && echo "  Killed $key (PID $pid)." || echo "  Failed."; }
        fi
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
        if [ "$force" = "--force" ]; then
          kill "$pid" 2>/dev/null && echo "  Killed $sname (PID $pid, port :$sport)" || true
        else
          _wt_prompt "  Kill $sname (PID $pid, port :$sport)? [y/N]"
          [[ "$REPLY" =~ ^[Yy]$ ]] && { kill "$pid" 2>/dev/null && echo "  Killed $sname (PID $pid)." || echo "  Failed."; }
        fi
      fi
    done < <(jq -c '.services[]' "$devrc")
  fi

  [ "$found" = false ] && [ "$force" != "--force" ] && echo "No dev server processes found for $target_path."
  [ "$kill_errors" -gt 0 ] && return 1
  return 0
}

_dev_status() {
  # Worktree-centric dashboard showing all dev servers, ports, PIDs, status, uptime.
  _wt_check_jq || return 1

  local devrc
  devrc=$(_dev_find_devrc)
  if [ $? -ne 0 ]; then
    echo "No .devrc.json found. Run dev init to set up."
    return 1
  fi

  local repo_root
  repo_root="$(_wt_ensure_git_root)" || return 1

  echo ""
  printf "%-20s %-12s %-7s %-8s %-10s %s\n" "WORKTREE" "SERVICE" "PORT" "PID" "STATUS" "UPTIME"
  printf "%-20s %-12s %-7s %-8s %-10s %s\n" "────────" "───────" "────" "───" "──────" "──────"

  local has_entries=false

  # Main repo
  _dev_status_for_path "__main__" "$repo_root" "$devrc" && has_entries=true

  # Worktrees
  if [ -d "$repo_root/.worktrees" ]; then
    for wt_dir in "$repo_root/.worktrees"/*/; do
      [ -d "$wt_dir" ] || continue
      local wt_name
      wt_name="$(basename "$wt_dir")"
      _dev_status_for_path "$wt_name" "${wt_dir%/}" "$devrc" && has_entries=true
    done
  fi

  if [ "$has_entries" = false ]; then
    echo "(no services configured)"
  fi

  echo ""
  echo "* = detected via port scan (not started with 'dev start')"
}

_dev_mprocs() {
  # Launches mprocs TUI for dev servers in the current context.
  # Args: [name]  (worktree name, or auto-detect from cwd)
  local name="$1"
  _wt_check_jq || return 1

  if ! command -v mprocs &>/dev/null; then
    echo "mprocs is not installed."
    echo "  brew install mprocs"
    echo "  or: cargo install mprocs"
    return 1
  fi

  local devrc
  devrc=$(_dev_find_devrc)
  if [ $? -ne 0 ]; then
    echo "No .devrc.json found. Run dev init to set up."
    return 1
  fi

  local repo_root
  repo_root="$(_wt_ensure_git_root)" || return 1

  # Detect context
  local worktree_path wt_name is_main ctx
  ctx="$(_dev_detect_context "$repo_root" "$name")" || return 1
  IFS=$'\t' read -r worktree_path wt_name is_main <<< "$ctx"

  local ports_json
  ports_json="$(_dev_resolve_ports "$devrc" "$repo_root" "$worktree_path" "$is_main")" || return 1

  local pid_dir
  pid_dir="$(_dev_pid_dir "$worktree_path")" || return 1

  # Generate mprocs.yaml
  local yaml_file="$pid_dir/mprocs.yaml"
  local yaml_content="procs:"
  local has_procs=false

  while IFS= read -r svc; do
    local sname scmd main_only allocated final_cmd
    sname=$(echo "$svc" | jq -r '.name')
    scmd=$(echo "$svc" | jq -r '.cmd')
    main_only=$(echo "$svc" | jq -r '.main_only // false')

    # Skip main_only services in worktrees
    if [ "$is_main" != "true" ] && [ "$main_only" = "true" ]; then
      continue
    fi

    allocated=$(echo "$ports_json" | jq -r --arg n "$sname" '.[$n]')
    if [ -z "$allocated" ] || [ "$allocated" = "null" ]; then
      allocated=$(echo "$svc" | jq -r '.port')
    fi
    final_cmd="${scmd//\{port\}/$allocated}"

    # Write a launcher script per service to avoid YAML/shell escaping issues.
    # Dynamic values go in an unquoted heredoc header (variable assignments are safe),
    # then the logic body uses a quoted heredoc so no expansion happens at write-time.
    local launcher="$pid_dir/${sname}.sh"
    {
      echo '#!/usr/bin/env bash'
      # Write variable assignments using printf %q for safe shell escaping
      printf '_DEV_CWD=%q\n' "$worktree_path"
      printf '_DEV_PORT=%q\n' "$allocated"
      printf '_DEV_CMD=%q\n' "$final_cmd"
      printf '_DEV_PID_FILE=%q\n' "$pid_dir/$sname.pid"
      cat <<'LAUNCHER'
cd "$_DEV_CWD" || exit 1
jq -n --argjson pid "$$" --argjson port "$_DEV_PORT" --arg cmd "$_DEV_CMD" \
  --arg started "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{"pid":$pid,"port":$port,"cmd":$cmd,"started":$started}' \
  > "$_DEV_PID_FILE"
eval exec "$_DEV_CMD"
LAUNCHER
    } > "$launcher"
    chmod +x "$launcher"

    # Escape any single quotes in the launcher path for YAML single-quote context
    local yaml_safe_launcher="${launcher//\'/\'\\\'\'}"
    yaml_content="$yaml_content
  ${sname}:
    shell: \"bash '${yaml_safe_launcher}'\""
    has_procs=true
  done < <(jq -c '.services[]' "$devrc")

  if [ "$has_procs" = false ]; then
    echo "No services to run."
    return 0
  fi

  echo "$yaml_content" > "$yaml_file"

  echo "Launching mprocs for ${wt_name}..."
  echo "  Config: $yaml_file"
  echo ""

  exec mprocs --config "$yaml_file"
}

_dev_help() {
  cat <<'HELP'
Dev Workspace Launcher for Claude Code
=======================================

Usage:
  dev [name] [base]      Create/enter worktree + show workspace setup with ports
                          No args in main repo → default ports
                          No args in worktree → worktree ports
  dev -- <name>           Force enter (bypass subcommand matching)

Subcommands:
  dev init               Scaffold .devrc.json (auto-detects vite, convex, next)
  dev start [service]    Start dev server(s) in background with PID tracking
  dev stop [name]        Kill dev servers for a worktree (auto-detects from cwd)
                          --force: skip prompts (used by wt done/cleanup)
  dev ps                 Show running dev servers, flag orphans, prompt to kill
  dev status             Dashboard: all worktrees, services, ports, PIDs, uptime
  dev mprocs [name]      Launch mprocs TUI for dev servers (requires mprocs)
  dev help               Show this help

Server management:
  'dev start' launches servers in background with PID file tracking.
  PID files are stored in .pids/<service>.pid (JSON with pid, port, cmd, started).
  'dev stop' kills via PID files first, falls back to port-based lsof detection.
  'wt done' / 'wt cleanup' auto-kill servers via PID files before removing worktrees.
  'dev mprocs' provides a TUI (terminal UI) for managing all services interactively.

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

Data files (per worktree):
  .ports.json            Port allocations (written by dev, stable across sessions)
  .pids/<service>.pid    PID tracking (JSON: pid, port, cmd, started timestamp)
  .pids/<service>.log    Server stdout/stderr (from dev start)

Requirements: jq, wt.sh (sourced before dev.sh)
Optional: mprocs (for dev mprocs TUI)
HELP
}

# ─── Dispatcher ──────────────────────────────────────────────────────────────

unalias dev 2>/dev/null  # prevent zsh alias-expansion parse error if 'dev' is already aliased
dev() {
  if [ "$1" = "--" ]; then shift; _dev_enter "$@"; return $?; fi
  case "$1" in
    init)           shift; _dev_init "$@" ;;
    start)          shift; _dev_start "$@" ;;
    stop)           shift; _dev_stop "$@" ;;
    ps)             shift; _dev_ps "$@" ;;
    status)         shift; _dev_status "$@" ;;
    mprocs)         shift; _dev_mprocs "$@" ;;
    help|-h|--help) _dev_help ;;
    *)              _dev_enter "$@" ;;
  esac
}

# ─── Backward-Compat Wrappers ───────────────────────────────────────────────

dev-init()   { dev init "$@"; }
dev-start()  { dev start "$@"; }
dev-stop()   { dev stop "$@"; }
dev-ps()     { dev ps "$@"; }
dev-status() { dev status "$@"; }
dev-mprocs() { dev mprocs "$@"; }
dev-help()   { dev help; }
