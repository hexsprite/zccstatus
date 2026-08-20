#!/bin/sh
# zccstatus installer.
#
#   curl -fsSL https://raw.githubusercontent.com/hexsprite/zccstatus/main/install.sh | sh
#
# Environment:
#   ZCC_VERSION      tag to install (default: latest release)
#   ZCC_INSTALL_DIR  where the binary goes (default: ~/.local/bin)
set -eu

REPO="hexsprite/zccstatus"
INSTALL_DIR="${ZCC_INSTALL_DIR:-$HOME/.local/bin}"
SETTINGS="$HOME/.claude/settings.json"

say() { printf '%s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "$1 is required but not installed"; }
need curl
need tar

# --- which build ------------------------------------------------------------
os=$(uname -s)
arch=$(uname -m)
case "$os/$arch" in
  Darwin/arm64)          target=macos-arm64 ;;
  Darwin/x86_64)         target=macos-x86_64 ;;
  Linux/x86_64|Linux/amd64) target=linux-x86_64 ;;
  Linux/aarch64|Linux/arm64) target=linux-arm64 ;;
  *) die "no prebuilt binary for $os/$arch. Build from source: zig build -Doptimize=ReleaseFast" ;;
esac

# --- which version ----------------------------------------------------------
version="${ZCC_VERSION:-}"
if [ -z "$version" ]; then
  version=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
    | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
  [ -n "$version" ] || die "could not determine the latest release"
fi

say "zccstatus $version for $target"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

base="https://github.com/$REPO/releases/download/$version"
tarball="zccstatus-$version-$target.tar.gz"

say "downloading $tarball"
curl -fsSL "$base/$tarball" -o "$tmp/$tarball" || die "download failed"

# --- verify -----------------------------------------------------------------
if curl -fsSL "$base/checksums.txt" -o "$tmp/checksums.txt" 2>/dev/null; then
  want=$(grep " $tarball\$" "$tmp/checksums.txt" | awk '{print $1}')
  if [ -n "$want" ]; then
    if command -v shasum >/dev/null 2>&1; then
      got=$(shasum -a 256 "$tmp/$tarball" | awk '{print $1}')
    elif command -v sha256sum >/dev/null 2>&1; then
      got=$(sha256sum "$tmp/$tarball" | awk '{print $1}')
    else
      got=""
    fi
    if [ -n "$got" ] && [ "$got" != "$want" ]; then
      die "checksum mismatch: expected $want, got $got"
    fi
    [ -n "$got" ] && say "checksum ok"
  fi
fi

# --- install ----------------------------------------------------------------
tar -xzf "$tmp/$tarball" -C "$tmp"
binary=$(find "$tmp" -type f -name zccstatus -perm -u+x | head -1)
[ -n "$binary" ] || die "archive did not contain a zccstatus binary"

mkdir -p "$INSTALL_DIR"
install -m 0755 "$binary" "$INSTALL_DIR/zccstatus" 2>/dev/null \
  || { cp "$binary" "$INSTALL_DIR/zccstatus" && chmod 0755 "$INSTALL_DIR/zccstatus"; }
say "installed $INSTALL_DIR/zccstatus"

case ":$PATH:" in
  *":$INSTALL_DIR:"*) ;;
  *) say ""; say "note: $INSTALL_DIR is not on your PATH." ;;
esac

# --- wire it into Claude Code ----------------------------------------------
snippet='  "statusLine": {
    "type": "command",
    "command": "'"$INSTALL_DIR"'/zccstatus --theme neon",
    "padding": 0,
    "refreshInterval": 5
  }'

configure() {
  [ -f "$SETTINGS" ] || return 1
  command -v python3 >/dev/null 2>&1 || return 1
  cp "$SETTINGS" "$SETTINGS.bak.$(date +%Y%m%d-%H%M%S)"
  ZCC_BIN="$INSTALL_DIR/zccstatus" python3 - "$SETTINGS" <<'PY'
import json, os, sys
p = sys.argv[1]
with open(p) as f:
    d = json.load(f)
d["statusLine"] = {
    "type": "command",
    "command": os.environ["ZCC_BIN"] + " --theme neon",
    "padding": 0,
    "refreshInterval": 5,
}
with open(p, "w") as f:
    json.dump(d, f, indent=2)
    f.write("\n")
PY
}

# Piping the script into sh leaves stdin pointing at the script, so the prompt
# has to come from the terminal. That terminal may not exist: in CI, in a
# container, or under a process with no controlling tty. Opening it must be
# allowed to fail without taking the whole install down.
ask() {
  if [ -t 0 ]; then
    printf '%s' "$1"
    read -r reply || return 1
    return 0
  fi
  [ -c /dev/tty ] || return 1
  { exec 3</dev/tty; } 2>/dev/null || return 1
  printf '%s' "$1"
  if read -r reply <&3; then
    exec 3<&-
    return 0
  fi
  exec 3<&-
  return 1
}

manual() {
  say "Add this to $SETTINGS:"
  say ""
  say "$snippet"
}

say ""
reply=""
if ask 'Set zccstatus as your Claude Code status line now? [y/N] '; then
  say ""
  case "$reply" in
    [yY]*)
      if configure; then
        say "updated $SETTINGS (previous version saved alongside it)"
        say "refreshInterval is set to 5: the cache countdown needs a timer to tick."
      else
        say "could not update $SETTINGS automatically."
        manual
      fi
      ;;
    *) manual ;;
  esac
else
  manual
fi

say ""
say "Try it:  zccstatus --demo"
