#!/usr/bin/env bash
# vectored: push config sets to one or more targets using rsync over ssh.

# shellcheck disable=SC2317  # Don't warn about unreachable commands in this file

set -euo pipefail

PROG="vectored"

# Build-time injected version (set by CI packaging). Keep this placeholder in git.
VECTORED_BUILD_VERSION='@VECTORED_VERSION@'

# Resolve real path of this script (handles symlinks)
_self="${BASH_SOURCE[0]}"
while [[ -L "$_self" ]]; do
  _dir="$(cd -P -- "$(dirname -- "$_self")" && pwd)"
  _self="$(readlink -- "$_self")"
  [[ "$_self" != /* ]] && _self="$_dir/$_self"
done
SCRIPT_DIR="$(cd -P -- "$(dirname -- "$_self")" && pwd)"

# Prefer repo/local layout first, then FHS install layout
COMMON_CANDIDATES=(
  "${SCRIPT_DIR}/lib/common.sh"     # repo layout (./lib)
  "${SCRIPT_DIR}/common.sh"         # if you ever flatten
  "/usr/lib/vectored/lib/common.sh" # packaged FHS layout
)

COMMON_SH=""
for c in "${COMMON_CANDIDATES[@]}"; do
  if [[ -f "$c" ]]; then
    COMMON_SH="$c"
    break
  fi
done

if [[ -z "$COMMON_SH" ]]; then
  echo "vectored: cannot find lib/common.sh. Tried:" >&2
  printf '  - %s\n' "${COMMON_CANDIDATES[@]}" >&2
  exit 1
fi

# shellcheck disable=SC1090
source "$COMMON_SH"

# Defaults (can be overridden by env)
CONF_ROOT="${VECTORED_CONF_ROOT:-/etc/vectored}"
DEFAULT_INVENTORY_DIR="${CONF_ROOT}/inventory.d"
DEFAULT_SET_DIR="${CONF_ROOT}/sets.d"
DEFAULT_LOCK_DIR="${VECTORED_LOCK_DIR:-/run}"

INVENTORY_PATH=""
SET_PATH=""
DRYRUN=0
DO_DELETE=0
SYSLOG=0
MAIL_ON_FAIL=0
MAIL_TO="${VECTORED_MAIL_TO:-}"
MAIL_SUBJECT_PREFIX="${VECTORED_MAIL_SUBJECT_PREFIX:-[vectored]}"
TARGET_FILTER="" # comma-separated names to include, e.g. "axon,myelin"
# VERBOSE=0
LOCK_NAME="" # allow caller to override lock identity

vectored_version() {
  # If CI injected a real version, use it.
  _VECTORED_VERSION_PLACEHOLDER="@""VECTORED_VERSION""@" # construct to avoid replacement

  if [[ "$VECTORED_BUILD_VERSION" != "$_VECTORED_VERSION_PLACEHOLDER" ]]; then
    echo "$VECTORED_BUILD_VERSION"
    return 0
  fi

  # Dev fallback: if running from a git checkout, show a useful string.
  if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git describe --tags --dirty --always 2>/dev/null && return 0
  fi

  echo "dev"
}

usage() {
  cat <<EOF
NSYS Vectored $(vectored_version) - Systemd-based config synchronization across server clusters

Usage:
  $PROG --inventory <file|name> --set <file|name> [options]

Required:
  --inventory <file|name>   Inventory file or name in ${DEFAULT_INVENTORY_DIR}/
  --set <file|name>         Set file or name in ${DEFAULT_SET_DIR}/

Options:
  --dry-run                 Perform rsync dry run
  --delete                  Enable rsync --delete (dangerous; default off)
  --syslog                  Mirror logs to syslog via logger(1)
  --mail-on-fail            Send email notification on failure
  --mail-to <addr>          Recipient for failure emails
  --target <a,b,c>          Only run for these target names (inventory entries' NAME field)
  --lock-name <name>        Override lock name (default derived from inventory+set)
  -v, --verbose             More logging
  -h, --help                Show this help

Notes:
- If you pass a bare name to --inventory/--set, we look under:
    ${DEFAULT_INVENTORY_DIR}/NAME[.conf|.inventory]
    ${DEFAULT_SET_DIR}/NAME[.conf|.set]
- Inventories and sets are shell files. Keep them trusted / root-owned.
EOF
}

resolve_conf_path() {
  local kind="$1" value="$2" dir="$3"
  if [[ -f "$value" ]]; then
    echo "$value"
    return 0
  fi

  # Try common extensions
  local try
  for try in \
    "${dir}/${value}" \
    "${dir}/${value}.conf" \
    "${dir}/${value}.${kind}"; do
    if [[ -f "$try" ]]; then
      echo "$try"
      return 0
    fi
  done

  die "Could not resolve ${kind} path from '${value}' (tried in ${dir})"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h | --help)
        usage
        exit 0
        ;;
      -v | --version)
        vectored_version
        exit 0
        ;;
      --inventory)
        INVENTORY_PATH="$2"
        shift 2
        ;;
      --set)
        SET_PATH="$2"
        shift 2
        ;;
      --dry-run)
        DRYRUN=1
        shift
        ;;
      --delete)
        DO_DELETE=1
        shift
        ;;
      --syslog)
        SYSLOG=1
        shift
        ;;
      --mail-on-fail)
        MAIL_ON_FAIL=1
        shift
        ;;
      --mail-to)
        MAIL_TO="$2"
        shift 2
        ;;
      --target)
        TARGET_FILTER="$2"
        shift 2
        ;;
      --lock-name)
        LOCK_NAME="$2"
        shift 2
        ;;
      # Currently unused
      # --verbose)
      #   VERBOSE=1
      #   shift
      #   ;;
      *) die "Unknown argument: $1" ;;
    esac
  done

  [[ -n "$INVENTORY_PATH" && -n "$SET_PATH" ]] || {
    usage
    exit 2
  }

  INVENTORY_PATH="$(resolve_conf_path "inventory" "$INVENTORY_PATH" "$DEFAULT_INVENTORY_DIR")"
  SET_PATH="$(resolve_conf_path "set" "$SET_PATH" "$DEFAULT_SET_DIR")"
}

main() {
  parse_args "$@"

  require_cmd bash date ssh rsync
  if [[ "$SYSLOG" -eq 1 ]]; then
    require_cmd logger
    enable_syslog
  fi

  # shellcheck disable=SC1090
  source "$INVENTORY_PATH"
  # shellcheck disable=SC1090
  source "$SET_PATH"

  [[ -n "${SET_NAME:-}" ]] || die "SET_NAME missing in set file: $SET_PATH"
  [[ ${#TARGETS[@]} -gt 0 ]] || die "TARGETS missing/empty in inventory file: $INVENTORY_PATH"
  [[ ${#SOURCES[@]} -gt 0 ]] || die "SOURCES missing/empty in set file: $SET_PATH"

  # Derived lock name
  if [[ -z "$LOCK_NAME" ]]; then
    LOCK_NAME="$(basename "$INVENTORY_PATH")__$(basename "$SET_PATH")"
  fi

  # Acquire lock (prevents overlapping timers)
  acquire_lock "${DEFAULT_LOCK_DIR}/${PROG}.${LOCK_NAME}.lock"

  # Make filter set (names to include)
  local -A ONLY=()
  if [[ -n "$TARGET_FILTER" ]]; then
    IFS=',' read -r -a _names <<<"$TARGET_FILTER"
    local n
    for n in "${_names[@]}"; do
      n="${n// /}"
      [[ -n "$n" ]] && ONLY["$n"]=1
    done
  fi

  # Print header
  log_info "== $PROG starting =="
  log_info "Inventory: $INVENTORY_PATH"
  log_info "Set:       $SET_PATH"
  log_info "SET_NAME:  $SET_NAME"
  log_info "Dry-run:   $DRYRUN"
  log_info "Delete:    $DO_DELETE"
  log_info "Syslog:    $SYSLOG"
  log_info "MailFail:  $MAIL_ON_FAIL (to=${MAIL_TO:-<unset>})"

  local rsync_flags=()
  [[ "$DRYRUN" -eq 1 ]] && rsync_flags+=(--dry-run)
  # Keep delete off by default
  [[ "$DO_DELETE" -eq 1 ]] && rsync_flags+=(--delete)

  local -a rsync_ex=()
  if [[ -n "${RSYNC_EXCLUDES+x}" && ${#RSYNC_EXCLUDES[@]} -gt 0 ]]; then
    local ex
    for ex in "${RSYNC_EXCLUDES[@]}"; do
      rsync_ex+=(--exclude "$ex")
    done
  fi
  # Run
  local failures=0
  local entry name host port
  for entry in "${TARGETS[@]}"; do
    IFS='|' read -r name host port <<<"$entry"

    if [[ ${#ONLY[@]} -gt 0 && -z "${ONLY[$name]+x}" ]]; then
      log_info "Skipping target '$name' due to --target filter"
      continue
    fi

    if [[ -z "$name" || -z "$host" || -z "$port" ]]; then
      log_warn "bad target entry '$entry' (expected NAME|HOST|PORT), skipping"
      continue
    fi

    if run_target "$name" "$host" "$port" "${rsync_flags[@]}" "${rsync_ex[@]}"; then
      : # ok
    else
      failures=$((failures + 1))
    fi
  done

  if [[ "$failures" -gt 0 ]]; then
    log_warn "== $PROG finished with FAILURES: $failures =="
    exit 1
  fi

  log_info "== $PROG finished OK =="
  exit 0
}

run_target() {
  local name="$1" host="$2" port="$3"
  shift 3

  local -a rsync_flags=()
  local -a rsync_ex=()

  # Parse forwarded args safely:
  # - allow: --exclude PATTERN (can repeat)
  # - everything else goes to rsync_flags
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --exclude)
        [[ $# -ge 2 ]] || {
          log_error "ERROR: --exclude needs a value"
          return 2
        }
        rsync_ex+=(--exclude "$2")
        shift 2
        ;;
      *)
        rsync_flags+=("$1")
        shift
        ;;
    esac
  done

  local var="REMOTE_BASE__${name}"
  local remote_base="${!var:-/}"

  local stage="${remote_base%/}${REMOTE_STAGING:-/var/lib/vectored/stage/${SET_NAME}}"
  local live="${remote_base%/}${REMOTE_LIVE:-/etc}"

  if [[ -n "${REMOTE_STAGING:-}" ]]; then stage="${remote_base%/}${REMOTE_STAGING}"; fi
  if [[ -n "${REMOTE_LIVE:-}" ]]; then live="${remote_base%/}${REMOTE_LIVE}"; fi

  # Capture a per-target log buffer (for email)
  local logbuf
  logbuf="$(mktemp)"

  # Save original stdout/stderr to anonymous fds (avoids "3: Bad file descriptor")
  local fd_out fd_err
  exec {fd_out}>&1
  exec {fd_err}>&2

  cleanup_run_target() {
    # Restore stdout/stderr; ignore fd errors
    { exec 1>&"$fd_out" 2>&"$fd_err"; } 2>/dev/null || true
    # Close the saved fds; ignore fd errors
    { exec {fd_out}>&-; } 2>/dev/null || true
    { exec {fd_err}>&-; } 2>/dev/null || true
    rm -f "$logbuf" 2>/dev/null || true
  }
  trap cleanup_run_target RETURN

  # Duplicate output into the log file without pipelines (preserves set -e)
  exec > >(tee -a "$logbuf" >&"$fd_out") 2> >(tee -a "$logbuf" >&"$fd_err")

  log_info "---- Target '$name' ($host:$port) ----"
  log_info "Stage: $stage"
  log_info "Live:  $live"

  # Preflight remote basics
  run_ssh "$host" "$port" "command -v rsync >/dev/null && mkdir -p '$stage'"

  # Push sources -> stage
  local stage_root="$stage"  # rename for clarity
  local src rel

  for src in "${SOURCES[@]}"; do
    if [[ ! -e "$src" ]]; then
      log_warn "source missing: $src"
      continue
    fi

    rel="${src#/}"  # absolute -> relative path under stage_root

    if [[ -d "$src" ]]; then
      # Ensure parent exists, then sync the directory itself
      run_ssh "$host" "$port" "mkdir -p '$stage_root/$(dirname -- "$rel")'" || return 1
      log_info "Rsync -> stage: $src  =>  $stage_root/$rel/"
      run_rsync "$port" "$src" "${host}:${stage_root}/${rel%/}/" "${rsync_flags[@]}" "${rsync_ex[@]}" \
        || { log_error "rsync failed for '$name'"; return 1; }
    else
      # Ensure parent exists, then sync the file to the exact path
      run_ssh "$host" "$port" "mkdir -p '$stage_root/$(dirname -- "$rel")'" || return 1
      log_info "Rsync -> stage: $src  =>  $stage_root/$rel"
      run_rsync "$port" "$src" "${host}:${stage_root}/${rel}" "${rsync_flags[@]}" "${rsync_ex[@]}" \
        || { log_error "rsync failed for '$name'"; return 1; }
    fi
  done

  # Optional validate
  if [[ -n "${REMOTE_VALIDATE:-}" ]]; then
    log_info "Validate: ${REMOTE_VALIDATE}"
    run_ssh "$host" "$port" "cd '$stage' && ${REMOTE_VALIDATE}" || return 1
  fi

  # Promote stage -> live
  log_info "Promote stage -> live"
  local root relroot

  while IFS= read -r root; do
    [[ -n "$root" ]] || continue
    relroot="${root#/}"  # e.g. etc/nginx

    # Sanity: staged root must exist
    run_ssh "$host" "$port" "test -e '$stage_root/$relroot'" \
      || { log_error "stage missing expected root: $stage_root/$relroot"; return 1; }

    # Guard: refuse overly-broad roots (must be at least two levels deep, like /etc/nginx)
    # Counts path segments after the leading slash.
    case "$root" in
      "/"|"" )
        log_error "Refusing to promote root path: '$root'"
        return 2
        ;;
    esac

    # Strip trailing slash, then count segments
    _trimmed="${root%/}"
    _segments="${_trimmed#/}"
    depth=0
    IFS='/' read -r -a _parts <<<"$_segments"
    depth="${#_parts[@]}"

    if [[ "$depth" -lt 2 ]]; then
      log_error "Refusing to promote overly broad root (depth=$depth): $root"
      return 2
    fi

    # Promote directory roots (or parent dirs for files) onto their absolute location
    log_info "Promote: $stage_root/$relroot  =>  /$relroot"
    # shellcheck disable=SC2029
    run_ssh "$host" "$port" "rsync -aHAX --numeric-ids ${DO_DELETE:+--delete} '$stage_root/$relroot/' '/$relroot/'" \
      || { log_error "promote failed for root: /$relroot"; return 1; }
  done < <(compute_promote_roots)
}

send_failure_email() {
  local name="$1" rc="$2" logbuf="$3"

  if [[ -z "$MAIL_TO" ]]; then
    log_warn "Mail requested but MAIL_TO is empty; skipping email."
    return 0
  fi

  local subject="${MAIL_SUBJECT_PREFIX} FAIL ${SET_NAME} -> ${name} (rc=${rc})"
  local body
  body="$(
    cat <<EOF
vectored failure

Set:       ${SET_NAME}
Target:    ${name}
Exit code: ${rc}
Host time: $(date -Is)

Inventory: ${INVENTORY_PATH}
Set file:  ${SET_PATH}

---- log ----
$(tail -n 200 "$logbuf")
EOF
  )"

  mail_send "$MAIL_TO" "$subject" "$body" || true
}

main "$@"
