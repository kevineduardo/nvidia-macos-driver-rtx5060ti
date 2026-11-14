#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 kevineduardo
# uninstall.sh: removes what install.sh installed and its PATH block from ~/.zprofile / ~/.bash_profile
set -uo pipefail
sudo rm -f /usr/local/bin/nvenc-run; sudo rm -rf /usr/local/libexec/nvenc-run
for f in "$HOME/.zprofile" "$HOME/.bash_profile"; do
  [ -f "$f" ] || continue
  if grep -q '# >>> nvenc-run:' "$f"; then
    sed -i '' '/# >>> nvenc-run:/,/# <<< nvenc-run <<</d' "$f"; echo "PATH block removed from $f"
  fi
done
echo "nvenc-run removed"
