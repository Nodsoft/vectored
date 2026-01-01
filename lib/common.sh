#!/usr/bin/env bash
# Common helpers for vectored
set -euo pipefail

_SYSLOG_ENABLED=0
_SYSLOG_TAG="${VECTORED_SYSLOG_TAG:-vectored}"
_USE_SYSCAT=0
command -v systemd-cat >/dev/null 2>&1 && _USE_SYSCAT=1

_is_systemd() {
  # INVOCATION_ID is set for systemd services; JOURNAL_STREAM is another hint.
  [[ -n "${INVOCATION_ID:-}" || -n "${JOURNAL_STREAM:-}" ]]
}

_is_tty() {
  [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]
}

_c() { # _c "ANSI" "text"
  if _is_tty; then
    printf '\033[%sm%s\033[0m' "$1" "$2"
  else
    printf '%s' "$2"
  fi
}

jlog() {
  # Usage: jlog <prio> <message...>
  # prio: emerg alert crit err warning notice info debug
  local prio="$1"
  shift
  local msg="$*"

  if _is_systemd && [[ "$_USE_SYSCAT" -eq 1 ]]; then
    # Best effort: never let logging break the program exit code
    printf '%s\n' "$msg" | systemd-cat -t "$_SYSLOG_TAG" -p "$prio" >/dev/null 2>&1 || true
    return 0
  else
    # Interactive/non-systemd fallback: timestamped stdout + optional color label
    local label
    case "$prio" in
      err | crit | alert | emerg) label="$(_c '0;31' 'ERROR')" ;;
      warning) label="$(_c '0;33' 'WARN ')" ;;
      notice) label="$(_c '0;32' 'OK   ')" ;;
      debug) label="$(_c '0;90' 'DEBUG')" ;;
      *) label="$(_c '0;36' 'INFO ')" ;;
    esac
    printf '%s %s %s\n' "$(date -Is)" "$label" "$msg"
  fi
}

# Convenience helpers
log_info() { jlog info "$*"; }
log_warn() { jlog warning "$*"; }
log_error() { jlog err "$*"; }
log_ok() { jlog notice "$*"; }
log_debug() { jlog debug "$*"; }

# Backward-compatible default
log() { log_info "$*"; }

die() {
  log_error "$*"
  exit 2
}

require_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "Missing required command: $c"
  done
}

enable_syslog() {
  _SYSLOG_ENABLED=1
}

# Global lock using flock. Falls back to mkdir lock if flock isn't available.
acquire_lock() {
  local lockfile="$1"

  if command -v flock >/dev/null 2>&1; then
    # Open FD 9 and lock it
    exec 9>"$lockfile"
    if ! flock -n 9; then
      die "Another instance is already running (lock: $lockfile)"
    fi
    return 0
  fi

  # Fallback: mkdir lock
  local lockdir="${lockfile}.d"
  if ! mkdir "$lockdir" 2>/dev/null; then
    die "Another instance is already running (lock: $lockdir)"
  fi
  trap 'rmdir "$lockdir" 2>/dev/null || true' EXIT
}

run_ssh() {
  local host="$1" port="$2" cmd="$3"
  # SSH_OPTS is expected from inventory, but tolerate missing.
  # shellcheck disable=SC2086
  ssh -p "$port" ${SSH_OPTS:-} "$host" "$cmd"
}

run_rsync() {
  local port="$1" src="$2" dst="$3"
  shift 3

  # Baseline flags: keep it faithful and permission-aware
  # --delay-updates reduces partial state; --delete is controlled by caller.
  # shellcheck disable=SC2086
  rsync -aHAX --numeric-ids --delete-delay --delay-updates \
    -e "ssh -p $port ${SSH_OPTS:-}" \
    "$@" \
    "$src" "$dst"
}

mail_send() {
  local to="$1" subject="$2" body="$3"

  if command -v mail >/dev/null 2>&1; then
    printf '%s\n' "$body" | mail -s "$subject" "$to"
    return 0
  fi

  if command -v sendmail >/dev/null 2>&1; then
    {
      echo "To: $to"
      echo "Subject: $subject"
      echo
      printf '%s\n' "$body"
    } | sendmail -t
    return 0
  fi

  log "WARN: cannot send mail (no 'mail' or 'sendmail' found)."
  return 1
}

compute_promote_roots() {
  # Outputs a newline-separated list of absolute roots derived from SOURCES:
  # - file -> dirname(file)
  # - dir  -> dir itself (trim trailing /)
  local src root
  for src in "${SOURCES[@]}"; do
    [[ -e "$src" ]] || continue
    if [[ -d "$src" ]]; then
      root="${src%/}"
    else
      root="$(dirname -- "$src")"
    fi
    printf '%s\n' "$root"
  done | awk '!seen[$0]++'
}