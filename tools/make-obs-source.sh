#!/usr/bin/env bash
#
# make-obs-source.sh - Build a Debian "3.0 (quilt)" source package from git HEAD
#                      without requiring dpkg-dev on the build host.
#
# Produces, under build/obs/ :
#   <pkg>_<upstream>.orig.tar.gz          upstream tree (no debian/)
#   <pkg>_<version>.debian.tar.xz         the debian/ directory
#   <pkg>_<version>.dsc                   Debian source control (with checksums)
#
# These three files are what OBS (obs.opensuse.org) consumes to build the .deb.
# Versions are taken from debian/changelog (authoritative for Debian).
#
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
OUT="$ROOT/build/obs"

# --- derive identifiers ----------------------------------------------------
PKG="$(sed -n '1s/^\([a-z0-9.+-]*\) .*/\1/p' debian/changelog)"
FULLVER="$(sed -n '1s/^[^(]*(\([^)]*\)).*/\1/p' debian/changelog)"   # e.g. 1.2.0-1
UPSTREAM="${FULLVER%-*}"                                              # e.g. 1.2.0
[ "$UPSTREAM" = "$FULLVER" ] && { echo "native versions unsupported here" >&2; exit 1; }

# fields pulled from debian/control for the .dsc
MAINT="$(sed -n 's/^Maintainer: //p' debian/control)"
STDVER="$(sed -n 's/^Standards-Version: //p' debian/control)"
BDEPS="$(sed -n 's/^Build-Depends: //p' debian/control | tr -d '\n')"
BIN="$(sed -n 's/^Package: //p' debian/control | head -1)"

echo ">> $PKG  upstream=$UPSTREAM  debian=$FULLVER"
rm -rf "$OUT"
mkdir -p "$OUT"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --- 1. orig tarball: tracked tree at HEAD, minus debian/ ------------------
git archive --format=tar --prefix="$PKG-$UPSTREAM/" HEAD | tar -x -C "$WORK"
rm -rf "$WORK/$PKG-$UPSTREAM/debian"
# deterministic tar (sorted, fixed owner/mtime from the HEAD commit)
MTIME="$(git show -s --format=%cI HEAD)"
tar --sort=name --owner=0 --group=0 --numeric-owner --mtime="$MTIME" \
    -C "$WORK" -czf "$OUT/${PKG}_${UPSTREAM}.orig.tar.gz" "$PKG-$UPSTREAM"

# --- 2. debian tarball: the packaging dir ----------------------------------
git archive --format=tar --prefix=debian/ HEAD:debian/ | tar -x -C "$WORK"
tar --sort=name --owner=0 --group=0 --numeric-owner --mtime="$MTIME" \
    -C "$WORK" -cJf "$OUT/${PKG}_${FULLVER}.debian.tar.xz" debian

# --- 3. the .dsc -----------------------------------------------------------
ORIG="${PKG}_${UPSTREAM}.orig.tar.gz"
DEB="${PKG}_${FULLVER}.debian.tar.xz"
DSC="$OUT/${PKG}_${FULLVER}.dsc"

field() { # algo file -> "  <sum> <size> <name>"
  local sum size
  case "$1" in
    md5)    sum=$(md5sum    "$OUT/$2" | cut -d' ' -f1) ;;
    sha1)   sum=$(sha1sum   "$OUT/$2" | cut -d' ' -f1) ;;
    sha256) sum=$(sha256sum "$OUT/$2" | cut -d' ' -f1) ;;
  esac
  size=$(stat -c%s "$OUT/$2")
  printf ' %s %s %s\n' "$sum" "$size" "$2"
}

{
  echo "Format: 3.0 (quilt)"
  echo "Source: $PKG"
  echo "Binary: $BIN"
  echo "Architecture: all"
  echo "Version: $FULLVER"
  echo "Maintainer: $MAINT"
  echo "Standards-Version: $STDVER"
  echo "Build-Depends: $BDEPS"
  echo "Package-List:"
  echo " $BIN deb admin optional arch=all"
  echo "Checksums-Sha1:"
  field sha1 "$ORIG"; field sha1 "$DEB"
  echo "Checksums-Sha256:"
  field sha256 "$ORIG"; field sha256 "$DEB"
  echo "Files:"
  field md5 "$ORIG"; field md5 "$DEB"
} > "$DSC"

echo ">> wrote:"
ls -l "$OUT"
