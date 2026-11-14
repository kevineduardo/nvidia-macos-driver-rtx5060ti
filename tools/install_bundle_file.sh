#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 kevineduardo
# install_bundle_file.sh <new file> <name in the bundle's MacOS folder>
#   e.g. install_bundle_file.sh out/libnvencvt.dylib libnvencvt.dylib
#        install_bundle_file.sh out/NVMTLDriver NVMTLDriver
#
# Replaces ONE file of the installed /Library/GPUBundles/NVMTLDriver.bundle and seals the bundle again, touching nothing
# else in it. Asks for sudo.
#
# Why a script: `codesign --force --deep` on the bundle signs every library in it again. Until the plugin took the shader
# cache's tag from the translator's content (plugin/nvmtl_translator_tag.h), that changed the tag, every process swept
# its shader cache, and the next boot left the screen black for two minutes while WindowServer translated everything and
# the watchdog killed it once. This signs only the new file, seals without --deep, and STOPS if any other file of the
# bundle changed (the main executable is signed again by the seal: its code, by LC_UUID, must be the same).
#   - the old file and the old seal go to /Library/NullMoth/backup-bundle-<time>/
#   - the new file is put in place by rename, so a process that has the old one mapped keeps it
#   - processes started afterwards load the new file; WindowServer keeps the old one until the next restart
set -euo pipefail
NEW=${1:?the new file}; NAME=${2:?its name in Contents/MacOS}
B=${NVMTL_BUNDLE:-/Library/GPUBundles/NVMTLDriver.bundle}; M=$B/Contents/MacOS
[ -f "$NEW" ] || { echo "STOP: $NEW does not exist"; exit 1; }
[ -f "$M/$NAME" ] || { echo "STOP: $M/$NAME does not exist (this replaces a file, it does not add one)"; exit 1; }
lipo -archs "$NEW" 2>/dev/null | grep -qw x86_64 || { echo "STOP: $NEW is not an x86_64 Mach-O"; exit 1; }
# Every other file by its digest. The bundle's main executable is the exception: sealing the bundle signs it again
# (its signature carries the seal), so it is compared by its LC_UUID, which is its code.
MAIN=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$B/Contents/Info.plist" 2>/dev/null || echo NVMTLDriver)
sums() { (cd "$M" && find . -type f ! -name "$NAME" ! -name ".$NAME.new" ! -name "$MAIN" -exec shasum -a 256 {} + | LC_ALL=C sort -k2
          [ "$NAME" = "$MAIN" ] || echo "uuid $(otool -l "$MAIN" | awk '/uuid/{print $2; exit}')  ./$MAIN"); }
before=$(sums)
BK=${NVMTL_BACKUP_ROOT:-/Library/NullMoth}/backup-bundle-$(date +%Y%m%d-%H%M%S)
sudo mkdir -p "$BK"; sudo cp -p "$M/$NAME" "$BK/"; sudo cp -Rp "$B/Contents/_CodeSignature" "$BK/_CodeSignature"; sudo chmod 700 "$BK"
sudo install -m 755 -o root -g wheel "$NEW" "$M/.$NAME.new"
sudo codesign -f -s - "$M/.$NAME.new" >/dev/null 2>&1 || { sudo rm -f "$M/.$NAME.new"; echo "STOP: could not sign the new file"; exit 1; }
sudo mv -f "$M/.$NAME.new" "$M/$NAME"
sudo codesign --force -s - "$B" >/dev/null 2>&1 || { echo "STOP: could not seal $B (the old file is in $BK)"; exit 1; }   # no --deep
sudo codesign --verify --deep --strict "$B" || { echo "STOP: the seal of $B does not verify (the old file is in $BK)"; exit 1; }
after=$(sums)
if [ "$before" != "$after" ]; then
  echo "STOP: files other than $NAME changed in the bundle:"; diff <(echo "$before") <(echo "$after") | sed -n 's/^[<>] [0-9a-f]*  //p' | sort -u
  echo "the old $NAME and seal are in $BK"; exit 1
fi
echo "installed $NAME ($(shasum -a 256 "$M/$NAME" | cut -c1-12)); nothing else in the bundle changed; backup in $BK"
