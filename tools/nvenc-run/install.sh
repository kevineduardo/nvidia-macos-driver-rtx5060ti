#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 kevineduardo
# install.sh [--no-profile]: installs nvenc-run in /usr/local/bin and the wrappers (ffmpeg, ffprobe, ffplay,
# HandBrakeCLI, avconvert) in /usr/local/libexec/nvenc-run/bin, and puts that folder first in PATH for login shells
# through a marked block in ~/.zprofile (and ~/.bash_profile if it exists). --no-profile leaves the shell files alone.
# Asks for sudo for /usr/local. uninstall.sh undoes all of it.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
BIN=/usr/local/bin; LX=/usr/local/libexec/nvenc-run; TOOLS="ffmpeg ffprobe ffplay HandBrakeCLI avconvert"
sudo mkdir -p "$BIN" "$LX/bin"
sudo install -m 755 "$HERE/nvenc-run" "$BIN/nvenc-run"
sudo install -m 755 "$HERE/shim" "$LX/shim"
for t in $TOOLS; do sudo ln -sf ../shim "$LX/bin/$t"; done
echo "installed $BIN/nvenc-run and wrappers in $LX/bin: $TOOLS"
START='# >>> nvenc-run: hardware video codecs for command-line tools >>>'; END='# <<< nvenc-run <<<'
add() { f=$1; [ -f "$f" ] && grep -qF "$START" "$f" && { echo "PATH block already in $f"; return; }
  printf '\n%s\nexport PATH="%s:$PATH"\n%s\n' "$START" "$LX/bin" "$END" >> "$f"; echo "PATH block added to $f"; }
if [ "${1-}" != "--no-profile" ]; then
  add "$HOME/.zprofile"
  [ -f "$HOME/.bash_profile" ] && add "$HOME/.bash_profile"
  echo "open a new terminal (or: export PATH=\"$LX/bin:\$PATH\") for plain 'ffmpeg' to go through it"
else
  echo "PATH not changed: use 'nvenc-run ffmpeg ...', or put $LX/bin first in PATH yourself"
fi
