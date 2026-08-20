#!/usr/bin/env bash
# Build every release target into dist/, with tarballs and checksums.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: build-release.sh vX.Y.Z}"
OUT=dist
rm -rf "$OUT"; mkdir -p "$OUT"

# Friendly name -> zig target triple.
TARGETS="
macos-arm64:aarch64-macos
macos-x86_64:x86_64-macos
linux-x86_64:x86_64-linux-musl
linux-arm64:aarch64-linux-musl
"

for entry in $TARGETS; do
  name="${entry%%:*}"
  triple="${entry##*:}"
  echo "building $name ($triple)"
  zig build -Doptimize=ReleaseFast -Dstrip=true -Dtarget="$triple"

  stage="$OUT/zccstatus-$VERSION-$name"
  mkdir -p "$stage"
  cp zig-out/bin/zccstatus "$stage/"
  cp README.md LICENSE "$stage/"
  tar -czf "$OUT/zccstatus-$VERSION-$name.tar.gz" -C "$OUT" "zccstatus-$VERSION-$name"
  rm -rf "$stage"
done

cd "$OUT"
shasum -a 256 ./*.tar.gz | sed 's|\./||' > checksums.txt
echo
ls -lh
echo
cat checksums.txt
