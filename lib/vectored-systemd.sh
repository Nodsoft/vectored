#!/usr/bin/env bash
set -euo pipefail

INST="${1:-}"
shift || true

if [[ -z "$INST" ]]; then
  echo "vectored-systemd: missing instance argument (<inventory>:<set>)" >&2
  exit 2
fi

# Parse "<inventory>:<set>"
INV="${INST%%:*}"
SET="${INST#*:}"

if [[ "$INV" == "$INST" || -z "$INV" || -z "$SET" ]]; then
  echo "vectored-systemd: instance must be <inventory>:<set> (got: $INST)" >&2
  exit 2
fi

CONF_ROOT="${VECTORED_CONF_ROOT:-/etc/vectored}"

INV_FILE="${CONF_ROOT}/inventory.d/${INV}.inventory"
SET_FILE="${CONF_ROOT}/sets.d/${SET}.set"

if [[ ! -f "$INV_FILE" ]]; then
  echo "vectored-systemd: inventory not found: $INV_FILE" >&2
  exit 2
fi

if [[ ! -f "$SET_FILE" ]]; then
  echo "vectored-systemd: set not found: $SET_FILE" >&2
  exit 2
fi

# Optional env layering (order: global -> inventory -> set -> instance)
for f in \
  "${CONF_ROOT}/profiles/default.env" \
  "${CONF_ROOT}/profiles/${INV}.env" \
  "${CONF_ROOT}/profiles/${SET}.env" \
  "${CONF_ROOT}/profiles/${INV}:${SET}.env"; do
  if [[ -f "$f" ]]; then
    # shellcheck disable=SC1090
    source "$f"
  fi
done

# Execute vectored with syslog enabled, passing all extra args
exec /usr/lib/vectored/vectored.sh \
  --inventory "$INV_FILE" \
  --set "$SET_FILE" \
  --syslog \
  "$@"
