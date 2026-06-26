#!/usr/bin/env zsh
# server.zsh — locate llama-server, manage one server keyed by port.

server::run_dir()  { print -r -- "$(config::state_dir)/run"; }
server::log_dir()  { print -r -- "$(config::state_dir)/log"; }
server::metafile() { print -r -- "$(server::run_dir)/$1.meta"; }
server::logfile()  { print -r -- "$(server::log_dir)/$1.log"; }

# server::resolve_bin -> path to llama-server (built prefix first, then PATH).
server::resolve_bin() {
  local built="$(config::bin_dir)/llama-server"
  if [[ -x "$built" ]]; then print -r -- "$built"; return 0; fi
  command -v llama-server 2>/dev/null && return 0
  return 1
}

# server::lib_dir -> dir to prepend to (DY)LD_LIBRARY_PATH for the launch.
server::lib_dir() {
  local bin; bin="$(server::resolve_bin)" || return 1
  print -r -- "${bin:h}"
}

# server::build_args <profile> <model> <alias> <port> -> prints the llama-server argv (space-joined).
server::build_args() {
  local profile="$1" model="$2" alias="$3" port="$4"
  local -a a
  if [[ -f "$model" ]]; then a+=(--model "$model"); else a+=(--hf-repo "$model"); fi
  a+=(--alias "$alias" --port "$port")
  a+=(--ctx-size "$(config::ctx_size "$profile")")
  a+=(--flash-attn "$(config::pf "$profile" flash_attn)")
  a+=(--jinja)
  a+=(--n-gpu-layers "$(config::pf "$profile" gpu_layers)")
  local _ckpts; _ckpts="$(config::pf "$profile" ctx_checkpoints)"
  [[ -n "$_ckpts" ]] && a+=(--ctx-checkpoints "$_ckpts")
  local _par; _par="$(config::pf "$profile" parallel)"
  [[ -n "$_par" ]] && a+=(--parallel "$_par")
  [[ "$(config::pf "$profile" warmup)" == 0 ]] && a+=(--no-warmup)
  [[ "$(config::pf "$profile" mmap)"   == 0 ]] && a+=(--no-mmap)
  print -r -- "${a[*]}"
}

server::is_healthy() {
  curl -fsS "http://127.0.0.1:$1/health" >/dev/null 2>&1
}

# server::pids_on <port> -> PIDs of every llama-server launched for this port.
server::pids_on() { pgrep -f "llama-server.*--port $1( |\$)" 2>/dev/null; }

# server::await_health <port> [pid] -> 0 once /health responds; 1 if it never does
# (or the given pid exits first). Heartbeat every 30s. Shared by start (own pid) and
# ensure (attach to an in-flight start), so a second `llmm` waits instead of duplicating.
server::await_health() {
  local port="$1" pid="${2:-}" lf; lf="$(server::logfile "$port")"
  local i
  for (( i = 1; i <= 300; i++ )); do
    if server::is_healthy "$port"; then return 0; fi
    if [[ -n "$pid" ]] && ! kill -0 "$pid" 2>/dev/null; then
      ui::err "llama-server exited during startup. Last log lines:"; tail -20 "$lf" >&2; return 1
    fi
    sleep 2
    (( i % 15 == 0 )) && ui::info "still waiting ($(( i * 2 ))s)... loading/downloading weights; llama-server logs only to a TTY, so $lf may stay empty"
  done
  ui::err "llama-server did not become healthy within 600s. Last log lines:"; tail -20 "$lf" >&2
  return 1
}

server::meta_write() {  # <port> <pid> <model> <alias> <ctx> <profile>
  local port="$1"; mkdir -p "$(server::run_dir)"
  {
    print -r -- "pid=$2"
    print -r -- "model=$3"
    print -r -- "alias=$4"
    print -r -- "ctx_size=$5"
    print -r -- "profile=$6"
    print -r -- "started_at=$(date +%s)"
    print -r -- "logfile=$(server::logfile "$port")"
  } > "$(server::metafile "$port")"
}

server::meta_get() {  # <port> <key>
  local mf="$(server::metafile "$1")"
  [[ -f "$mf" ]] || return 1
  local line; line="$(grep "^$2=" "$mf" | head -1)"
  print -r -- "${line#*=}"
}

server::meta_clear() { rm -f "$(server::metafile "$1")"; }

# server::should_rotate <size_mib> <cap_mib> -> yes|no
server::should_rotate() { (( $1 > $2 )) && print -- yes || print -- no; }

server::rotate_log() {  # <port>
  local lf="$(server::logfile "$1")"
  [[ -f "$lf" ]] || return 0
  local mib=$(( $(stat -f%z "$lf" 2>/dev/null || stat -c%s "$lf") / 1048576 ))
  if [[ "$(server::should_rotate "$mib" "${LLMM_LOG_MAX_MIB:-50}")" == yes ]]; then
    mv -f "$lf" "$lf.1"
  fi
}

# server::start <profile> <model> <alias> <port> -> launches, waits health, writes meta.
server::start() {
  local profile="$1" model="$2" alias="$3" port="$4"
  local bin; bin="$(server::resolve_bin)" || ui::die "llama-server not found; run: evn install llmm"
  mkdir -p "$(server::run_dir)" "$(server::log_dir)"
  server::rotate_log "$port"
  local lf="$(server::logfile "$port")"
  local libdir="$(server::lib_dir)"
  local -a argv=("${(z)$(server::build_args "$profile" "$model" "$alias" "$port")}")

  ui::info "starting llama-server :$port  model=$model  profile=$profile"
  [[ -f "$model" ]] || ui::info "first run may download the model — this can take several minutes"

  export HF_HOME="$(config::models_dir)" LLAMA_CACHE="$(config::models_dir)"
  if [[ "$(uname)" == Darwin ]]; then
    DYLD_LIBRARY_PATH="$libdir${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}" "$bin" "${argv[@]}" >"$lf" 2>&1 &
  else
    LD_LIBRARY_PATH="$libdir${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$bin" "${argv[@]}" >"$lf" 2>&1 &
  fi
  local pid=$!
  # Record the pid immediately (not only on success) so a concurrent `llmm` sees a
  # start already in progress and attaches instead of launching a duplicate, and so
  # `llmm kill` can reap a server that is still downloading/loading.
  server::meta_write "$port" "$pid" "$model" "$alias" "$(config::ctx_size "$profile")" "$profile"

  if server::await_health "$port" "$pid"; then
    ui::info "server ready (pid $pid)"
    return 0
  fi
  server::meta_clear "$port"
  return 1
}

# server::ensure <profile> <model> <alias> <port> -> reuse healthy or start; handle mismatch.
server::ensure() {
  local profile="$1" model="$2" alias="$3" port="$4"
  if server::is_healthy "$port"; then
    local ralias="$(server::meta_get "$port" alias 2>/dev/null || true)"
    local rprof="$(server::meta_get "$port" profile 2>/dev/null || true)"
    if [[ -z "$ralias" ]]; then
      ui::warn "a foreign server is healthy on :$port (not started by llmm); reusing it"
      return 0
    fi
    # Identity is the canonical alias, so an HF repo spec and the downloaded
    # .gguf for the same model are treated as the same server (no restart prompt).
    if [[ "$ralias" == "$alias" && "$rprof" == "$profile" ]]; then
      ui::info "reusing running server :$port ($ralias)"
      return 0
    fi
    if [[ -t 0 ]]; then
      print -u2 -n "running server is $ralias ($rprof); switch to $alias ($profile)? [y/N] "
      local ans; read -r ans
      if [[ "$ans" == [yY]* ]]; then
        server::kill "$port"
        # Wait for the port to be released before binding a new server (kill is asynchronous).
        local _kw; for (( _kw = 1; _kw <= 10; _kw++ )); do
          server::is_healthy "$port" || break
          sleep 0.5
        done
        server::start "$profile" "$model" "$alias" "$port"; return
      fi
      ui::info "keeping $ralias"; return 0
    else
      ui::warn "non-interactive: keeping running $ralias despite requested $alias"; return 0
    fi
  fi
  # Not healthy. If a llama-server is already starting on this port, attach to its
  # startup rather than stacking a duplicate — llmm runs one instance per port.
  local inflight; inflight="$(server::pids_on "$port" | head -1)"
  if [[ -n "$inflight" ]]; then
    ui::info "a llama-server is already starting on :$port (pid $inflight); waiting for it instead of launching another"
    server::await_health "$port" "$inflight"; return
  fi
  server::start "$profile" "$model" "$alias" "$port"
}

# server::kill <port> -> stop every llama-server on this port (meta pid + all that
# match by command line), so one call fully clears the port even if duplicates stacked.
server::kill() {
  local -a pids
  local mp; mp="$(server::meta_get "$1" pid 2>/dev/null || true)"
  [[ -n "$mp" ]] && pids+=("$mp")
  local p
  for p in ${(f)"$(server::pids_on "$1")"}; do [[ -n "$p" ]] && pids+=("$p"); done
  pids=(${(u)pids})
  if (( ${#pids} == 0 )); then ui::info "no managed server on :$1"; server::meta_clear "$1"; return 0; fi
  for p in "${pids[@]}"; do
    kill -0 "$p" 2>/dev/null || continue
    ui::info "killing pid $p (:$1)"; kill "$p" 2>/dev/null
  done
  server::meta_clear "$1"
}
