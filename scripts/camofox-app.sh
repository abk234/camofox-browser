#!/usr/bin/env bash
# Start / stop / update camofox-browser locally (host npm or docker).
# SquadOS: telemetry off only (no LLM / SearXNG in this app).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CONFIG_FILE="${CAMOFOX_APP_CONFIG:-$ROOT/scripts/camofox-app.env}"
SYNC_SCRIPT="$ROOT/scripts/sync-upstream.sh"
PID_FILE="$ROOT/scripts/.camofox-server.pid"
LOG_FILE="${CAMOFOX_LOG_FILE:-$ROOT/scripts/camofox-server.log}"
LAN_PROXY="$ROOT/scripts/camofox-lan-proxy.py"
LAN_PROXY_PID="$ROOT/scripts/.camofox-lan-proxy.pid"

# Defaults (overridden by config / env)
RUN_MODE="${RUN_MODE:-host}"
CAMOFOX_PORT="${CAMOFOX_PORT:-9377}"
CAMOFOX_BIND_HOST="${CAMOFOX_BIND_HOST:-127.0.0.1}"
CAMOFOX_HOME="${CAMOFOX_HOME:-$HOME/.camofox}"
CAMOFOX_CRASH_REPORT_ENABLED="${CAMOFOX_CRASH_REPORT_ENABLED:-false}"
ENABLE_LAN_PROXY="${ENABLE_LAN_PROXY:-true}"
# Separate from CAMOFOX_PORT so 0.0.0.0 listen does not steal 127.0.0.1:9377 on macOS.
CAMOFOX_LAN_PORT="${CAMOFOX_LAN_PORT:-19377}"
BACKUP_DIR="${BACKUP_DIR:-$ROOT/../camofox-backups}"
BACKUP_INTERVAL_DAYS="${BACKUP_INTERVAL_DAYS:-30}"
BACKUP_KEEP="${BACKUP_KEEP:-3}"
UPDATE_SYNC_ON_UPDATE="${UPDATE_SYNC_ON_UPDATE:-true}"
DOCKER_NAME="${DOCKER_NAME:-camofox-browser}"

usage() {
  cat <<'EOF'
Usage: scripts/camofox-app.sh <command> [options]

Commands:
  setup                 Print capability wiring; ensure dirs + npm deps (host)
  start                 Start server (host npm or docker) + optional LAN proxy
  stop                  Stop server (keeps all data)
  down                  Alias for stop (docker: stop+rm container; never -v)
  status                Show process/container, ports, backup state
  backup                Backup CAMOFOX_HOME (+ env) now
  backup --if-due       Backup only if last one is older than BACKUP_INTERVAL_DAYS
  update                Backup (if due) → optional git sync → reinstall/restart
  schedule-hint         Print launchd / cron examples for monthly backups
  help                  Show this help

Update options:
  --sync / --no-sync    Force or skip git sync with upstream (default from config)
  --backup / --no-backup Force or skip pre-update backup
  --rebase              When syncing, rebase instead of merge

Config:
  Copy scripts/camofox-app.env.example → scripts/camofox-app.env
  Or set CAMOFOX_APP_CONFIG=/path/to/file

Capabilities (input repo):
  Telemetry: CAMOFOX_CRASH_REPORT_ENABLED=false
  LLM:       not applicable
  Search:    not applicable (browser macros only)
EOF
}

die() { echo "error: $*" >&2; exit 1; }
info() { echo "→ $*"; }
warn() { echo "warning: $*" >&2; }

load_config() {
  if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    set -a
    source "$CONFIG_FILE"
    set +a
  fi

  if [[ "$BACKUP_DIR" != /* ]]; then
    BACKUP_DIR="$ROOT/$BACKUP_DIR"
  fi
  if [[ "$CAMOFOX_HOME" == ~* ]]; then
    CAMOFOX_HOME="${CAMOFOX_HOME/#\~/$HOME}"
  fi
}

export_runtime_env() {
  export CAMOFOX_PORT
  export CAMOFOX_BIND_HOST
  export CAMOFOX_CRASH_REPORT_ENABLED
  export CAMOFOX_COOKIES_DIR="${CAMOFOX_COOKIES_DIR:-$CAMOFOX_HOME/cookies}"
  export CAMOFOX_PROFILE_DIR="${CAMOFOX_PROFILE_DIR:-$CAMOFOX_HOME/profiles}"
  export CAMOFOX_TRACES_DIR="${CAMOFOX_TRACES_DIR:-$CAMOFOX_HOME/traces}"
  export CAMOFOX_UPLOADS_DIR="${CAMOFOX_UPLOADS_DIR:-$CAMOFOX_HOME/uploads}"
  # Optional keys from config
  if [[ -n "${CAMOFOX_API_KEY:-}" ]]; then export CAMOFOX_API_KEY; fi
  if [[ -n "${CAMOFOX_ACCESS_KEY:-}" ]]; then export CAMOFOX_ACCESS_KEY; fi
  if [[ -n "${CAMOFOX_ADMIN_KEY:-}" ]]; then export CAMOFOX_ADMIN_KEY; fi
}

require_node() {
  command -v node >/dev/null 2>&1 || die "node is not installed"
  command -v npm >/dev/null 2>&1 || die "npm is not installed"
  local major
  major="$(node -p 'process.versions.node.split(".")[0]')"
  [[ "$major" -ge 22 ]] || die "node >= 22 required (found $(node -v))"
}

require_docker() {
  command -v docker >/dev/null 2>&1 || die "docker is not installed or not on PATH"
  docker info >/dev/null 2>&1 || die "docker is not running (start Docker Desktop)"
}

lan_ip() {
  ipconfig getifaddr en7 2>/dev/null || ipconfig getifaddr en0 2>/dev/null || true
}

ensure_data_dirs() {
  mkdir -p \
    "$CAMOFOX_HOME/cookies" \
    "$CAMOFOX_HOME/profiles" \
    "$CAMOFOX_HOME/traces" \
    "$CAMOFOX_HOME/uploads"
}

host_pid() {
  if [[ -f "$PID_FILE" ]]; then
    local pid
    pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      echo "$pid"
      return 0
    fi
  fi
  return 1
}

host_running() {
  host_pid >/dev/null 2>&1
}

docker_running() {
  docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$DOCKER_NAME"
}

stack_running() {
  if [[ "$RUN_MODE" == docker ]]; then
    docker_running
  else
    host_running
  fi
}

stop_lan_proxy() {
  if [[ -f "$LAN_PROXY_PID" ]]; then
    local pid
    pid="$(cat "$LAN_PROXY_PID" 2>/dev/null || true)"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      info "stopping LAN proxy (pid $pid)"
      kill "$pid" 2>/dev/null || true
    fi
    rm -f "$LAN_PROXY_PID"
  fi
  pkill -f 'camofox-lan-proxy.py' 2>/dev/null || true
}

start_lan_proxy() {
  [[ "$ENABLE_LAN_PROXY" == true || "$ENABLE_LAN_PROXY" == "1" ]] || return 0
  stop_lan_proxy
  [[ -f "$LAN_PROXY" ]] || die "missing $LAN_PROXY"
  info "starting LAN proxy (LAN:${CAMOFOX_LAN_PORT} → 127.0.0.1:${CAMOFOX_PORT})"
  python3 "$LAN_PROXY" \
    --listen-port "$CAMOFOX_LAN_PORT" \
    --target-port "$CAMOFOX_PORT" \
    --daemon \
    --pid-file "$LAN_PROXY_PID"
  sleep 0.3
  local lip
  lip="$(lan_ip)"
  if [[ -n "$lip" ]]; then
    info "phone / LAN URL: http://${lip}:${CAMOFOX_LAN_PORT}"
  else
    info "phone / LAN URL: http://<your-mac-lan-ip>:${CAMOFOX_LAN_PORT}"
  fi
}

cmd_setup() {
  load_config
  ensure_data_dirs

  echo "Capability wiring (from jo-inc/camofox-browser):"
  echo "  Telemetry: off (CAMOFOX_CRASH_REPORT_ENABLED=false)"
  echo "  LLM:       not applicable"
  echo "  Search:    not applicable"
  echo "  Data dir:  $CAMOFOX_HOME"
  echo "  Port:      $CAMOFOX_PORT (bind $CAMOFOX_BIND_HOST)"
  echo "  Mode:      $RUN_MODE"

  if [[ "$RUN_MODE" == host ]]; then
    require_node
    if [[ ! -d "$ROOT/node_modules" ]]; then
      info "npm install (first run downloads Camoufox ~300MB)"
      (cd "$ROOT" && npm install)
    else
      info "node_modules present"
    fi
  else
    require_docker
    info "docker mode — binaries fetched by make on start"
  fi

  if [[ ! -f "$CONFIG_FILE" ]]; then
    info "no $CONFIG_FILE — using defaults (copy .env.example to customize)"
  fi
}

cmd_start_host() {
  require_node
  export_runtime_env
  ensure_data_dirs

  if host_running; then
    info "already running (pid $(host_pid))"
    start_lan_proxy
    return 0
  fi

  if [[ ! -d "$ROOT/node_modules" ]]; then
    info "npm install"
    (cd "$ROOT" && npm install)
  fi

  info "starting camofox-browser (node) on ${CAMOFOX_BIND_HOST}:${CAMOFOX_PORT}"
  # Background; pid of node (not a shell wrapper)
  nohup node --max-old-space-size="${MAX_OLD_SPACE_SIZE:-128}" "$ROOT/server.js" \
    >>"$LOG_FILE" 2>&1 &
  echo $! >"$PID_FILE"
  sleep 1
  if ! host_running; then
    rm -f "$PID_FILE"
    die "server failed to stay up — see $LOG_FILE"
  fi
  info "pid $(host_pid); log $LOG_FILE"
  start_lan_proxy
  info "local URL: http://127.0.0.1:${CAMOFOX_PORT}/health"
}

cmd_start_docker() {
  require_docker
  export_runtime_env
  ensure_data_dirs

  if docker_running; then
    info "container $DOCKER_NAME already running"
    start_lan_proxy
    return 0
  fi

  # Prefer make up (fetches binaries + builds). Override publish to loopback.
  info "building/starting via make (image may take a while on first run)"
  local make_args=()
  [[ -n "${ARCH:-}" ]] && make_args+=(ARCH="$ARCH")
  [[ -n "${VERSION:-}" ]] && make_args+=(VERSION="$VERSION")
  [[ -n "${RELEASE:-}" ]] && make_args+=(RELEASE="$RELEASE")

  # make up uses -p 9377:9377; stop any stale and re-run with loopback bind.
  docker stop "$DOCKER_NAME" 2>/dev/null || true
  docker rm "$DOCKER_NAME" 2>/dev/null || true

  if ! docker image inspect "camofox-browser:${VERSION:-135.0.1}-${ARCH:-$(uname -m | sed 's/arm64/aarch64/')}" >/dev/null 2>&1; then
    (cd "$ROOT" && make "${make_args[@]}" build)
  fi

  local image
  image="camofox-browser:${VERSION:-135.0.1}-${ARCH:-$( [[ "$(uname -m)" == arm64 ]] && echo aarch64 || uname -m )}"
  # Resolve image name from make defaults if inspect fails
  if ! docker image inspect "$image" >/dev/null 2>&1; then
    image="$(docker images --format '{{.Repository}}:{{.Tag}}' | grep '^camofox-browser:' | head -n1 || true)"
    [[ -n "$image" ]] || die "no camofox-browser image; run: make build"
  fi

  docker run -d --restart unless-stopped --name "$DOCKER_NAME" --shm-size=2g \
    -p "127.0.0.1:${CAMOFOX_PORT}:9377" \
    -e CAMOFOX_CRASH_REPORT_ENABLED=false \
    -e "CAMOFOX_PORT=9377" \
    ${CAMOFOX_API_KEY:+-e CAMOFOX_API_KEY="$CAMOFOX_API_KEY"} \
    ${CAMOFOX_ACCESS_KEY:+-e CAMOFOX_ACCESS_KEY="$CAMOFOX_ACCESS_KEY"} \
    -v "$CAMOFOX_HOME:/home/node/.camofox" \
    "$image"

  start_lan_proxy
  info "local URL: http://127.0.0.1:${CAMOFOX_PORT}/health"
}

cmd_start() {
  load_config
  case "$RUN_MODE" in
    host) cmd_start_host ;;
    docker) cmd_start_docker ;;
    *) die "unknown RUN_MODE=$RUN_MODE (use host|docker)" ;;
  esac
  cmd_status
}

cmd_stop() {
  load_config
  stop_lan_proxy
  if [[ "$RUN_MODE" == docker ]]; then
    if docker_running || docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$DOCKER_NAME"; then
      info "stopping docker container $DOCKER_NAME (data retained)"
      docker stop "$DOCKER_NAME" 2>/dev/null || true
    else
      info "docker container not running"
    fi
  else
    if pid="$(host_pid 2>/dev/null)"; then
      info "stopping host server (pid $pid)"
      kill "$pid" 2>/dev/null || true
      # Give it a moment; escalate if needed
      for _ in 1 2 3 4 5; do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.4
      done
      if kill -0 "$pid" 2>/dev/null; then
        warn "forcing kill $pid"
        kill -9 "$pid" 2>/dev/null || true
      fi
      rm -f "$PID_FILE"
    else
      info "host server not running"
      rm -f "$PID_FILE"
    fi
  fi
}

cmd_down() {
  load_config
  stop_lan_proxy
  if [[ "$RUN_MODE" == docker ]]; then
    info "removing docker container $DOCKER_NAME (no volumes destroyed; bind mount kept)"
    docker stop "$DOCKER_NAME" 2>/dev/null || true
    docker rm "$DOCKER_NAME" 2>/dev/null || true
  else
    cmd_stop
  fi
}

last_backup_dir() {
  [[ -d "$BACKUP_DIR" ]] || return 1
  local latest
  latest="$(ls -1dt "$BACKUP_DIR"/20* 2>/dev/null | head -n1 || true)"
  [[ -n "$latest" ]] || return 1
  echo "$latest"
}

backup_age_days() {
  local latest mtime now
  latest="$(last_backup_dir)" || return 1
  if [[ -f "$latest/.camofox-backup-complete" ]]; then
    mtime="$(stat -f %m "$latest/.camofox-backup-complete" 2>/dev/null || stat -c %Y "$latest/.camofox-backup-complete")"
  else
    mtime="$(stat -f %m "$latest" 2>/dev/null || stat -c %Y "$latest")"
  fi
  now="$(date +%s)"
  echo $(( (now - mtime) / 86400 ))
}

prune_backups() {
  local keep="${BACKUP_KEEP:-3}"
  [[ "$keep" =~ ^[0-9]+$ ]] || return 0
  [[ -d "$BACKUP_DIR" ]] || return 0
  local i=0 dir
  while IFS= read -r dir; do
    [[ -n "$dir" ]] || continue
    i=$((i + 1))
    if [[ "$i" -gt "$keep" ]]; then
      info "pruning old backup: $dir"
      rm -rf "$dir"
    fi
  done < <(ls -1dt "$BACKUP_DIR"/20* 2>/dev/null || true)
}

do_backup() {
  load_config
  local if_due=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --if-due) if_due=true ;;
      *) die "unknown backup option: $1" ;;
    esac
    shift
  done

  if [[ "$if_due" == true ]]; then
    local age
    if age="$(backup_age_days 2>/dev/null)"; then
      if [[ "$age" -lt "$BACKUP_INTERVAL_DAYS" ]]; then
        info "backup not due (last was ${age}d ago; interval ${BACKUP_INTERVAL_DAYS}d)"
        return 0
      fi
    fi
  fi

  mkdir -p "$BACKUP_DIR"
  local stamp dest
  stamp="$(date +%Y%m%d-%H%M%S)"
  dest="$BACKUP_DIR/$stamp"
  mkdir -p "$dest"

  info "backing up to $dest"
  if [[ -d "$CAMOFOX_HOME" ]]; then
    mkdir -p "$dest/camofox-home"
    cp -a "$CAMOFOX_HOME/." "$dest/camofox-home/"
  else
    warn "CAMOFOX_HOME missing: $CAMOFOX_HOME"
  fi
  [[ -f "$CONFIG_FILE" ]] && cp -f "$CONFIG_FILE" "$dest/camofox-app.env" || true
  [[ -f "$ROOT/.env" ]] && cp -f "$ROOT/.env" "$dest/repo.env" || true

  cat >"$dest/MANIFEST.txt" <<EOF
created=$(date -u +%Y-%m-%dT%H:%M:%SZ)
hostname=$(hostname)
git_head=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)
run_mode=$RUN_MODE
port=$CAMOFOX_PORT
camofox_home=$CAMOFOX_HOME
EOF
  date -u +%Y-%m-%dT%H:%M:%SZ >"$dest/.camofox-backup-complete"
  prune_backups
  info "backup complete: $dest"
}

cmd_status() {
  load_config
  export_runtime_env
  local lip
  lip="$(lan_ip)"

  echo "config:     $CONFIG_FILE$([ -f "$CONFIG_FILE" ] && echo '' || echo ' (missing — using defaults)')"
  echo "mode:       $RUN_MODE"
  echo "port:       $CAMOFOX_PORT (bind $CAMOFOX_BIND_HOST)"
  echo "LAN proxy:  $ENABLE_LAN_PROXY (listen $CAMOFOX_LAN_PORT → 127.0.0.1:$CAMOFOX_PORT)"
  echo "local URL:  http://127.0.0.1:${CAMOFOX_PORT}"
  if [[ -n "$lip" && ( "$ENABLE_LAN_PROXY" == true || "$ENABLE_LAN_PROXY" == "1" ) ]]; then
    echo "LAN URL:    http://${lip}:${CAMOFOX_LAN_PORT}"
  fi
  echo "data:       $CAMOFOX_HOME"
  echo "telemetry:  CAMOFOX_CRASH_REPORT_ENABLED=$CAMOFOX_CRASH_REPORT_ENABLED"
  echo "LLM:        not applicable"
  echo "search:     not applicable"
  echo "backups:    $BACKUP_DIR (every ${BACKUP_INTERVAL_DAYS}d, keep $BACKUP_KEEP)"
  echo

  if [[ "$RUN_MODE" == docker ]]; then
    if docker_running; then
      docker ps --filter "name=^/${DOCKER_NAME}$" --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
    else
      echo "stack:      not running"
    fi
  else
    if pid="$(host_pid 2>/dev/null)"; then
      echo "stack:      running (pid $pid)"
      echo "log:        $LOG_FILE"
    else
      echo "stack:      not running"
    fi
  fi

  if curl -sf "http://127.0.0.1:${CAMOFOX_PORT}/health" >/dev/null 2>&1; then
    echo "health:     ok"
  else
    echo "health:     unreachable"
  fi
  echo

  local latest age
  if latest="$(last_backup_dir)"; then
    age="$(backup_age_days || echo '?')"
    echo "last backup: $latest (${age} day(s) ago)"
  else
    echo "last backup: none"
  fi
}

cmd_update() {
  load_config
  local do_sync="$UPDATE_SYNC_ON_UPDATE"
  local do_backup="if-due"
  local rebase=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --sync) do_sync=true ;;
      --no-sync) do_sync=false ;;
      --backup) do_backup=force ;;
      --no-backup) do_backup=skip ;;
      --rebase) rebase=true ;;
      *) die "unknown update option: $1" ;;
    esac
    shift
  done

  case "$do_backup" in
    force) do_backup ;;
    if-due) do_backup --if-due ;;
    skip) info "skipping backup (--no-backup)" ;;
  esac

  if [[ "$do_sync" == true || "$do_sync" == "true" ]]; then
    [[ -x "$SYNC_SCRIPT" ]] || die "missing $SYNC_SCRIPT"
    info "syncing from jo-inc/camofox-browser upstream"
    if [[ "$rebase" == true ]]; then
      "$SYNC_SCRIPT" sync --rebase
    else
      "$SYNC_SCRIPT" sync
    fi
  else
    info "skipping git sync"
  fi

  cmd_stop
  if [[ "$RUN_MODE" == host ]]; then
    require_node
    info "npm install"
    (cd "$ROOT" && npm install)
  else
    require_docker
    (cd "$ROOT" && make reset) || (cd "$ROOT" && make build)
  fi
  cmd_start
  info "update complete"
}

cmd_schedule_hint() {
  load_config
  local script="$ROOT/scripts/camofox-app.sh"
  cat <<EOF
# Cron (monthly check on the 1st at 03:15)
15 3 1 * * $script backup --if-due >>$BACKUP_DIR/backup.log 2>&1

# macOS LaunchAgent (~/Library/LaunchAgents/com.camofox.host-backup.plist)
# ProgramArguments: $script
#               backup
#               --if-due
# StartCalendarInterval: Day=1 Hour=3 Minute=15

Reload:
  launchctl bootout gui/\$(id -u) ~/Library/LaunchAgents/com.camofox.host-backup.plist
  launchctl bootstrap gui/\$(id -u) ~/Library/LaunchAgents/com.camofox.host-backup.plist

Config: $CONFIG_FILE
BACKUP_DIR=$BACKUP_DIR
BACKUP_INTERVAL_DAYS=$BACKUP_INTERVAL_DAYS
EOF
}

main() {
  load_config
  local cmd="${1:-}"
  [[ -n "$cmd" ]] || { usage; exit 1; }
  shift || true

  case "$cmd" in
    -h|--help|help) usage ;;
    setup) cmd_setup ;;
    start) cmd_start ;;
    stop) cmd_stop ;;
    down) cmd_down ;;
    status) cmd_status ;;
    backup) do_backup "$@" ;;
    update) cmd_update "$@" ;;
    schedule-hint) cmd_schedule_hint ;;
    *) die "unknown command: $cmd (try help)" ;;
  esac
}

main "$@"
