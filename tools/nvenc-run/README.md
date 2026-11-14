# nvenc-run: the hardware decoders for command-line tools

VideoToolbox copies its list of decoders before it starts the GPU, and starting the GPU is what loads the NVIDIA Metal
plugin, which registers libnvencvt. An app that draws before it decodes gets the hardware decoders; a command-line
tool's first session does not: `ffmpeg -hwaccel videotoolbox` falls back to software for H.264, VP9 and HEVC, and
fails for AV1 ("Your platform doesn't support hardware accelerated AV1 decoding").

`nvenc-run <tool> [args...]` loads libnvencvt into the tool from its start (`DYLD_INSERT_LIBRARIES`), so its first
session already has them. Nothing system-wide changes.

```sh
tools/nvenc-run/nvenc-run ffmpeg -hwaccel videotoolbox -i in.mkv out.mp4
tools/nvenc-run/nvenc-run --check ffmpeg     # can the library reach this tool?
tools/nvenc-run/install.sh                   # /usr/local/bin/nvenc-run, and plain `ffmpeg` etc. go through it
tools/nvenc-run/uninstall.sh
tools/nvenc-run/test.sh <ffmpeg> <vectors>   # plain against wrapped, each compared with the software decode
```

`install.sh` puts wrappers named ffmpeg, ffprobe, ffplay, HandBrakeCLI and avconvert in
`/usr/local/libexec/nvenc-run/bin` and that folder first in PATH (a marked block in `~/.zprofile`; `--no-profile`
leaves it alone). Each runs the real tool of that name, the next one in PATH; `NVENC_RUN_OFF=1` runs it as it is.

A tool with the hardened runtime and without the `allow-dyld-environment-variables` entitlement drops the variable
while AMFI is on (`--check` says so): run an ad hoc re-signed copy (`codesign -s - -f <copy>`).

---
Copyright (c) 2026 kevineduardo. Licensed under the MIT License (SPDX-License-Identifier: MIT).
