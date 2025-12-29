#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${OUT_DIR:-$ROOT/dist}"
ARCH="${ARCH:-amd64}"

# Prefer CI-provided version; fall back to git describe for local builds
VERSION="${VERSION:-}"
if [[ -z "$VERSION" ]]; then
  if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    VERSION="$(git describe --tags --dirty --always | sed 's/^v//')"
  else
    VERSION="0.0.0"
  fi
fi

PKG="vectored"
PKGROOT="$ROOT/pkgroot"

rm -rf "$PKGROOT"
mkdir -p "$OUT_DIR"

# --- filesystem skeleton ---
mkdir -p "$PKGROOT/DEBIAN"
mkdir -p "$PKGROOT/usr/lib/vectored"
mkdir -p "$PKGROOT/usr/sbin"
mkdir -p "$PKGROOT/lib/systemd/system"
mkdir -p "$PKGROOT/etc/vectored/inventory.d" "$PKGROOT/etc/vectored/sets.d" "$PKGROOT/etc/vectored/profiles"

# --- payload ---
install -m 0755 "$ROOT/vectored.sh" "$PKGROOT/usr/lib/vectored/vectored.sh"
install -m 0755 "$ROOT/lib/vectored-systemd.sh" "$PKGROOT/usr/lib/vectored/vectored-systemd.sh"
install -m 0755 "$ROOT/bin/vectored" "$PKGROOT/usr/sbin/vectored"

install -m 0644 "$ROOT/systemd/vectored@.service" "$PKGROOT/lib/systemd/system/vectored@.service"
install -m 0644 "$ROOT/systemd/vectored@.timer"  "$PKGROOT/lib/systemd/system/vectored@.timer"

# --- inject version into the installed script (no mutable version file) ---
# Use the placeholder method you already implemented
sed -i 's/\r$//' "$PKGROOT/usr/lib/vectored/vectored.sh"
sed -i "s|@VECTORED_VERSION@|$VERSION|g" "$PKGROOT/usr/lib/vectored/vectored.sh"

# --- metadata ---
cat >"$PKGROOT/DEBIAN/control" <<EOF
Package: $PKG
Version: $VERSION
Section: admin
Priority: optional
Architecture: any
Maintainer: Sakura Akeno Isayeki <sakura.isayeki+vectored@nodsoft.net>
Depends: bash (>= 4.0), rsync, openssh-client, systemd, syslog-ng | rsyslog | systemd-journald
Recommends: mailutils | bsd-mailx | msmtp-mta, util-linux
Description: NSYS Vectored - Config synchronization across server clusters
 Vectored pushes config sets to one or more servers using rsync over SSH.
 Includes systemd templated units and optional email/syslog reporting.
EOF

# Mark config dir files as conffiles (dirs themselves aren’t tracked; include placeholders)
# We add empty placeholder files so dpkg manages the dirs nicely.
touch "$PKGROOT/etc/vectored/inventory.d/.keep"
touch "$PKGROOT/etc/vectored/sets.d/.keep"
touch "$PKGROOT/etc/vectored/profiles/.keep"

cat >"$PKGROOT/DEBIAN/conffiles" <<EOF
/etc/vectored/inventory.d/.keep
/etc/vectored/sets.d/.keep
/etc/vectored/profiles/.keep
EOF

# --- maintainer scripts ---
cat >"$PKGROOT/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e

# Ensure directories exist (in case)
mkdir -p /etc/vectored/inventory.d /etc/vectored/sets.d /etc/vectored/profiles

# systemd reload
if command -v systemctl >/dev/null 2>&1; then
  systemctl daemon-reload >/dev/null 2>&1 || true
fi

exit 0
EOF
chmod 0755 "$PKGROOT/DEBIAN/postinst"

cat >"$PKGROOT/DEBIAN/prerm" <<'EOF'
#!/bin/sh
set -e

# Stop any running templated timers/services on package remove (best-effort)
if command -v systemctl >/dev/null 2>&1; then
  systemctl daemon-reload >/dev/null 2>&1 || true
fi

exit 0
EOF
chmod 0755 "$PKGROOT/DEBIAN/prerm"

# --- build ---
DEB_PATH="$OUT_DIR/${PKG}_${VERSION}_${ARCH}.deb"
dpkg-deb --build "$PKGROOT" "$DEB_PATH"

echo "Built: $DEB_PATH"