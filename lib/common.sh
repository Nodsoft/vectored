#!/usr/bin/env bash
# Common helpers for vectored
set -euo pipefail

_SYSLOG_ENABLED=0
_SYSLOG_TAG="${NSYS_SYNC_SYSLOG_TAG:-vectored}"

log() {
  # journald likes timestamps on stdout, too.
  printf '%s %s\n' "$(date -Is)" "$*"
  if [[ "${_SYSLOG_ENABLED}" -eq 1 ]]; then
    logger -t "${_SYSLOG_TAG}" -- "$*"
  fi
}

die() {
  log "ERROR: $*"
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
